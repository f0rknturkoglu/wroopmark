//! `wroopmark mcp`: a Model Context Protocol server over stdio, so agents
//! (Claude Code, Claude Desktop, Cursor…) can search and file the archive.
//!
//! It is the CLI binary in another mode: no extra process runs unless an
//! agent starts it, and it exits when the agent closes the pipe. Every tool
//! maps onto a command of [`crate::api`]; `--read-only` drops the writing ones.

use std::collections::HashMap;
use std::io::{BufRead, Write};
use std::sync::Arc;

use chrono::DateTime;
use serde_json::{Value, json};

use crate::api::{Library, VERSION, handle_value};

const PROTOCOL: &str = "2025-06-18";

const INSTRUCTIONS: &str = "wroopmark is the user's offline archive of saved posts (X, TikTok, Instagram, Reddit, web pages, \
local files) on their Mac. Use `search` first; it understands filters like tag:dev, from:@user, platform:x, site:github.com, \
has:image, has:video, folder:Name, after:2024-01, before:2025, is:untagged and \"exact phrases\". Matching ignores case and \
Turkish dotted/dotless i. Set semantic=true to also match by meaning (on-device), useful when the user describes something \
rather than quoting it. Use `get_item` for the full text, OCR text and the local file paths of pictures and videos.";

fn tools(read_only: bool) -> Value {
    let mut list = vec![
        json!({
            "name": "search",
            "description": "Search the archive. Returns matching items, newest saved first (or best match when there are words).",
            "inputSchema": {"type": "object", "properties": {
                "query": {"type": "string", "description": "Words and filters, e.g. `rust async tag:dev -from:@jack has:link after:2024`. Empty lists everything."},
                "semantic": {"type": "boolean", "description": "Also match by meaning with the on-device model (slower, first call ~1 s)."},
                "limit": {"type": "integer", "minimum": 1, "maximum": 100, "default": 20},
                "offset": {"type": "integer", "minimum": 0, "default": 0},
                "sort": {"type": "string", "enum": ["", "saved", "saved_asc", "posted", "posted_asc", "author"], "description": "Empty: relevance, else by date or author."}
            }},
            "annotations": {"readOnlyHint": true}
        }),
        json!({
            "name": "get_item",
            "description": "One item in full: text, OCR text of its pictures, quoted post, note, links, tags, folder and the local paths of its media files.",
            "inputSchema": {"type": "object", "properties": {"id": {"type": "string", "description": "Item id, e.g. x:1234 or tiktok:7194…"}}, "required": ["id"]},
            "annotations": {"readOnlyHint": true}
        }),
        json!({
            "name": "related",
            "description": "Items closest in meaning to the given one (needs on-device vectors).",
            "inputSchema": {"type": "object", "properties": {"id": {"type": "string"}, "limit": {"type": "integer", "minimum": 1, "maximum": 30, "default": 8}}, "required": ["id"]},
            "annotations": {"readOnlyHint": true}
        }),
        json!({
            "name": "search_links",
            "description": "The link pool: every outbound link found in saved posts, deduplicated (GitHub repos, papers, articles…).",
            "inputSchema": {"type": "object", "properties": {
                "query": {"type": "string"},
                "category": {"type": "string", "enum": ["github", "arxiv", "youtube", "drive", "mega", "twitter", "other"]},
                "limit": {"type": "integer", "minimum": 1, "maximum": 100, "default": 30}
            }},
            "annotations": {"readOnlyHint": true}
        }),
        json!({"name": "list_tags", "description": "All tags with item counts (hierarchical: dev/rust).", "inputSchema": {"type": "object", "properties": {}}, "annotations": {"readOnlyHint": true}}),
        json!({"name": "list_folders", "description": "All folders with item counts (subfolders as Parent/Child).", "inputSchema": {"type": "object", "properties": {}}, "annotations": {"readOnlyHint": true}}),
        json!({"name": "stats", "description": "Library size: items per platform, media on disk.", "inputSchema": {"type": "object", "properties": {}}, "annotations": {"readOnlyHint": true}}),
    ];
    if !read_only {
        list.extend([
            json!({
                "name": "save_url",
                "description": "Save a web page or post URL to the archive (downloads its text and media).",
                "inputSchema": {"type": "object", "properties": {
                    "url": {"type": "string"},
                    "tags": {"type": "array", "items": {"type": "string"}},
                    "note": {"type": "string"},
                    "folder": {"type": "string", "description": "Folder name; created if missing."}
                }, "required": ["url"]}
            }),
            json!({
                "name": "tag_items",
                "description": "Add and/or remove tags on items.",
                "inputSchema": {"type": "object", "properties": {
                    "ids": {"type": "array", "items": {"type": "string"}},
                    "add": {"type": "array", "items": {"type": "string"}},
                    "remove": {"type": "array", "items": {"type": "string"}}
                }, "required": ["ids"]},
                "annotations": {"idempotentHint": true}
            }),
            json!({
                "name": "move_to_folder",
                "description": "File items in a folder (created if missing), or take them out with an empty folder.",
                "inputSchema": {"type": "object", "properties": {
                    "ids": {"type": "array", "items": {"type": "string"}},
                    "folder": {"type": "string"}
                }, "required": ["ids", "folder"]},
                "annotations": {"idempotentHint": true}
            }),
            json!({
                "name": "set_note",
                "description": "Replace an item's personal note (empty clears it).",
                "inputSchema": {"type": "object", "properties": {"id": {"type": "string"}, "note": {"type": "string"}}, "required": ["id", "note"]},
                "annotations": {"idempotentHint": true}
            }),
        ]);
    }
    Value::Array(list)
}

fn iso(ts: Option<i64>) -> Value {
    ts.and_then(|t| DateTime::from_timestamp(t, 0)).map(|d| Value::String(d.format("%Y-%m-%dT%H:%M:%SZ").to_string())).unwrap_or(Value::Null)
}

fn clip(s: &str, n: usize) -> String {
    if s.chars().count() <= n { s.to_string() } else { format!("{}…", s.chars().take(n).collect::<String>()) }
}

struct Ctx<'a> {
    lib: &'a Arc<Library>,
    folders: Option<HashMap<i64, String>>,
}

impl Ctx<'_> {
    fn call(&self, req: Value) -> Result<Value, String> {
        let r = handle_value(self.lib, req);
        if r.get("ok").and_then(Value::as_bool) == Some(true) {
            Ok(r.get("data").cloned().unwrap_or(Value::Null))
        } else {
            Err(r.get("error").and_then(Value::as_str).unwrap_or("hata").to_string())
        }
    }

    fn folder_name(&mut self, id: Option<i64>) -> Value {
        let Some(id) = id else { return Value::Null };
        if self.folders.is_none() {
            let list = self.call(json!({"cmd": "folders"})).unwrap_or(Value::Null);
            self.folders = Some(
                list.as_array()
                    .map(|a| a.iter().filter_map(|f| Some((f.get("id")?.as_i64()?, f.get("name")?.as_str()?.to_string()))).collect())
                    .unwrap_or_default(),
            );
        }
        self.folders.as_ref().and_then(|m| m.get(&id)).map(|n| Value::String(n.clone())).unwrap_or(Value::Null)
    }

    fn folder_id(&mut self, name: &str) -> Result<Value, String> {
        let name = name.trim();
        if name.is_empty() {
            return Ok(Value::Null);
        }
        let list = self.call(json!({"cmd": "folders"}))?;
        let found = list.as_array().and_then(|a| {
            a.iter().find(|f| f.get("name").and_then(Value::as_str).is_some_and(|n| n.eq_ignore_ascii_case(name))).and_then(|f| f.get("id").cloned())
        });
        match found {
            Some(id) => Ok(id),
            None => Ok(self.call(json!({"cmd": "add_folder", "name": name}))?.get("id").cloned().unwrap_or(Value::Null)),
        }
    }

    /// What an agent needs to pick results without drowning in them.
    fn brief(&mut self, it: &Value) -> Value {
        let author = it
            .get("author_handle")
            .and_then(Value::as_str)
            .map(|h| format!("@{h}"))
            .or_else(|| it.get("author_name").and_then(Value::as_str).map(str::to_string));
        let media = it.get("media").and_then(Value::as_array).map(Vec::len).unwrap_or(0);
        let mut out = json!({
            "id": it.get("id"),
            "platform": it.get("platform"),
            "url": it.get("url"),
            "author": author,
            "title": it.get("title"),
            "text": clip(it.get("text").and_then(Value::as_str).unwrap_or(""), 500),
            "tags": it.get("tags"),
            "folder": self.folder_name(it.get("folder_id").and_then(Value::as_i64)),
            "posted": iso(it.get("created_at").and_then(Value::as_i64)),
            "saved": iso(it.get("saved_at").and_then(Value::as_i64)),
            "media": media,
        });
        if let Some(obj) = out.as_object_mut() {
            for key in ["note", "summary"] {
                if let Some(v) = it.get(key).filter(|v| !v.is_null()) {
                    obj.insert(key.into(), v.clone());
                }
            }
            obj.retain(|_, v| !v.is_null());
        }
        out
    }

    fn full(&mut self, it: &Value) -> Value {
        let mut out = self.brief(it);
        let lib_media = |name: &str| self.lib.media.path(name).display().to_string();
        let media: Vec<Value> = it
            .get("media")
            .and_then(Value::as_array)
            .map(|a| {
                a.iter()
                    .map(|m| {
                        json!({
                            "kind": m.get("kind"),
                            "file": m.get("file").and_then(Value::as_str).map(lib_media),
                            "video_file": m.get("video_file").and_then(Value::as_str).map(lib_media),
                            "alt": m.get("alt"),
                        })
                    })
                    .collect()
            })
            .unwrap_or_default();
        if let Some(obj) = out.as_object_mut() {
            obj.insert("text".into(), it.get("text").cloned().unwrap_or(Value::Null));
            obj.insert("media".into(), Value::Array(media));
            if let Some(t) = it.get("thread").and_then(Value::as_array).filter(|t| !t.is_empty()) {
                obj.insert("thread".into(), Value::Array(t.iter().map(|p| json!({"id": p.get("id"), "text": p.get("text")})).collect()));
            }
            for key in ["ocr", "links", "ai_tags"] {
                if let Some(v) = it.get(key).filter(|v| !v.is_null()) {
                    obj.insert(key.into(), v.clone());
                }
            }
            if let Some(e) = it.get("extra").and_then(Value::as_str) {
                obj.insert("article".into(), Value::String(clip(e, 6000)));
            }
            if let Some(q) = it.get("quote").filter(|q| q.is_object()) {
                obj.insert("quote".into(), json!({"url": q.get("url"), "author": q.get("author_handle"), "text": q.get("text")}));
            }
        }
        out
    }

    fn tool(&mut self, name: &str, args: &Value, read_only: bool) -> Result<Value, String> {
        let s = |k: &str| args.get(k).and_then(Value::as_str).unwrap_or("").to_string();
        let n = |k: &str, d: i64, max: i64| args.get(k).and_then(Value::as_i64).unwrap_or(d).clamp(0, max);
        let strings = |k: &str| args.get(k).cloned().filter(Value::is_array).unwrap_or_else(|| json!([]));
        let writes = matches!(name, "save_url" | "tag_items" | "move_to_folder" | "set_note");
        if writes && read_only {
            return Err("salt okunur mod".into());
        }
        match name {
            "search" => {
                let cmd = if args.get("semantic").and_then(Value::as_bool) == Some(true) { "semantic_search" } else { "search" };
                let r = self.call(
                    json!({"cmd": cmd, "q": s("query"), "limit": n("limit", 20, 100).max(1), "offset": n("offset", 0, 100_000), "sort": s("sort")}),
                )?;
                let items: Vec<Value> =
                    r.get("items").and_then(Value::as_array).map(|a| a.iter().map(|i| self.brief(i)).collect()).unwrap_or_default();
                Ok(json!({"total": r.get("total"), "items": items}))
            }
            "get_item" => {
                let r = self.call(json!({"cmd": "get", "id": s("id")}))?;
                if r.is_null() {
                    return Err(format!("kayıt yok: {}", s("id")));
                }
                Ok(self.full(&r))
            }
            "related" => {
                let r = self.call(json!({"cmd": "related", "id": s("id"), "limit": n("limit", 8, 30).max(1)}))?;
                Ok(Value::Array(r.as_array().map(|a| a.iter().map(|i| self.brief(i)).collect()).unwrap_or_default()))
            }
            "search_links" => {
                let mut req = json!({"cmd": "links_page", "q": s("query"), "limit": n("limit", 30, 100).max(1), "offset": 0});
                if let (Some(obj), Some(c)) = (req.as_object_mut(), args.get("category").and_then(Value::as_str)) {
                    obj.insert("category".into(), Value::String(c.to_string()));
                }
                self.call(req)
            }
            "list_tags" => self.call(json!({"cmd": "tags"})),
            "list_folders" => self.call(json!({"cmd": "folders"})),
            "stats" => self.call(json!({"cmd": "stats"})),
            "save_url" => {
                let folder = self.folder_id(&s("folder"))?;
                let r =
                    self.call(json!({"cmd": "add_url", "url": s("url"), "tags": strings("tags"), "note": args.get("note"), "folder_id": folder}))?;
                Ok(self.brief(&r))
            }
            "tag_items" => self.call(json!({"cmd": "edit_tags", "ids": strings("ids"), "add": strings("add"), "remove": strings("remove")})),
            "move_to_folder" => {
                let folder = self.folder_id(&s("folder"))?;
                self.call(json!({"cmd": "move_items_to_folder", "ids": strings("ids"), "folder_id": folder}))
            }
            "set_note" => self.call(json!({"cmd": "set_note", "id": s("id"), "note": s("note")})),
            other => Err(format!("bilinmeyen araç: {other}")),
        }
    }
}

/// `wroopmark://item/<id>` as Markdown, media links pointing at the files.
fn read_resource(lib: &Arc<Library>, uri: &str) -> Result<Value, Value> {
    let Some(id) = uri.strip_prefix("wroopmark://item/") else {
        return Err(json!({"code": -32602, "message": "beklenen: wroopmark://item/<id>"}));
    };
    let mut ctx = Ctx { lib, folders: None };
    let v = ctx.call(json!({"cmd": "get", "id": id})).ok().filter(|v| !v.is_null());
    let Some(v) = v else {
        return Err(json!({"code": -32002, "message": format!("kayıt yok: {id}")}));
    };
    let folder = ctx.folder_name(v.get("folder_id").and_then(Value::as_i64));
    let item: crate::model::Item = serde_json::from_value(v).unwrap_or_default();
    let (mut md, files) = crate::export::markdown(&item, folder.as_str());
    for f in files {
        md = md.replace(&format!("media/{f}"), &lib.media.path(&f).display().to_string());
    }
    Ok(json!({"contents": [{"uri": uri, "mimeType": "text/markdown", "text": md}]}))
}

/// Answers one JSON-RPC message; `None` for notifications.
pub fn respond(lib: &Arc<Library>, msg: &Value, read_only: bool) -> Option<Value> {
    let id = msg.get("id").cloned()?;
    let method = msg.get("method").and_then(Value::as_str).unwrap_or("");
    let params = msg.get("params").cloned().unwrap_or(Value::Null);
    let result = match method {
        "initialize" => Ok(json!({
            "protocolVersion": params.get("protocolVersion").and_then(Value::as_str).unwrap_or(PROTOCOL),
            "capabilities": {"tools": {"listChanged": false}, "resources": {"listChanged": false}},
            "serverInfo": {"name": "wroopmark", "title": "wroopmark", "version": VERSION},
            "instructions": INSTRUCTIONS,
        })),
        "ping" => Ok(json!({})),
        "tools/list" => Ok(json!({"tools": tools(read_only)})),
        // Items as readable notes: `wroopmark://item/<id>` (the same links the
        // app, Spotlight and exports use).
        "resources/templates/list" => Ok(json!({"resourceTemplates": [{
            "uriTemplate": "wroopmark://item/{id}",
            "name": "item",
            "title": "wroopmark kaydı",
            "description": "One saved item as Markdown: text, thread, tags, note, links and local media paths.",
            "mimeType": "text/markdown"
        }]})),
        "resources/list" => {
            let ctx = Ctx { lib, folders: None };
            let recent = ctx.call(json!({"cmd": "search", "q": "", "sort": "saved", "limit": 25})).unwrap_or(Value::Null);
            let list: Vec<Value> = recent
                .get("items")
                .and_then(Value::as_array)
                .map(|a| {
                    a.iter()
                        .filter_map(|i| {
                            let id = i.get("id")?.as_str()?;
                            let item: crate::model::Item = serde_json::from_value(i.clone()).ok()?;
                            Some(
                                json!({"uri": format!("wroopmark://item/{id}"), "name": crate::export::title_of(&item), "mimeType": "text/markdown"}),
                            )
                        })
                        .collect()
                })
                .unwrap_or_default();
            Ok(json!({"resources": list}))
        }
        "resources/read" => read_resource(lib, params.get("uri").and_then(Value::as_str).unwrap_or("")),
        "tools/call" => {
            let name = params.get("name").and_then(Value::as_str).unwrap_or("");
            let args = params.get("arguments").cloned().unwrap_or_else(|| json!({}));
            let mut ctx = Ctx { lib, folders: None };
            Ok(match ctx.tool(name, &args, read_only) {
                Ok(v) => json!({"content": [{"type": "text", "text": serde_json::to_string_pretty(&v).unwrap_or_default()}], "isError": false}),
                Err(e) => json!({"content": [{"type": "text", "text": e}], "isError": true}),
            })
        }
        other => Err(json!({"code": -32601, "message": format!("method not found: {other}")})),
    };
    Some(match result {
        Ok(r) => json!({"jsonrpc": "2.0", "id": id, "result": r}),
        Err(e) => json!({"jsonrpc": "2.0", "id": id, "error": e}),
    })
}

/// Reads newline-delimited JSON-RPC from stdin until it closes.
pub fn serve(lib: &Arc<Library>, read_only: bool) -> std::io::Result<()> {
    let stdin = std::io::stdin();
    let mut out = std::io::stdout().lock();
    for line in stdin.lock().lines() {
        let line = line?;
        if line.trim().is_empty() {
            continue;
        }
        let reply = match serde_json::from_str::<Value>(&line) {
            Ok(Value::Array(batch)) => {
                let replies: Vec<Value> = batch.iter().filter_map(|m| respond(lib, m, read_only)).collect();
                (!replies.is_empty()).then_some(Value::Array(replies))
            }
            Ok(msg) => respond(lib, &msg, read_only),
            Err(e) => Some(json!({"jsonrpc": "2.0", "id": null, "error": {"code": -32700, "message": e.to_string()}})),
        };
        if let Some(r) = reply {
            writeln!(out, "{r}")?;
            out.flush()?;
        }
    }
    lib.shutdown();
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn answers_the_protocol() {
        let dir = std::env::temp_dir().join(format!("wm-mcp-{}", std::process::id()));
        let lib = Library::open(&dir).unwrap_or_else(|_| std::process::abort());
        let init = respond(&lib, &json!({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-03-26"}}), false);
        assert_eq!(init.as_ref().and_then(|r| r.pointer("/result/protocolVersion")), Some(&json!("2025-03-26")));
        assert!(respond(&lib, &json!({"jsonrpc": "2.0", "method": "notifications/initialized"}), false).is_none());
        let list = respond(&lib, &json!({"jsonrpc": "2.0", "id": 2, "method": "tools/list"}), true);
        let names: Vec<String> = list
            .as_ref()
            .and_then(|r| r.pointer("/result/tools"))
            .and_then(Value::as_array)
            .map(|a| a.iter().filter_map(|t| t.get("name").and_then(Value::as_str).map(str::to_string)).collect())
            .unwrap_or_default();
        assert!(names.contains(&"search".to_string()) && !names.contains(&"save_url".to_string()));

        handle_value(
            &lib,
            json!({"cmd": "import_items", "items": [{"platform": "web", "url": "https://example.com/mcp", "text": "Istanbul notları"}]}),
        );
        let r = respond(
            &lib,
            &json!({"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "search", "arguments": {"query": "İSTANBUL"}}}),
            false,
        );
        let text = r.as_ref().and_then(|r| r.pointer("/result/content/0/text")).and_then(Value::as_str).unwrap_or("");
        assert!(text.contains("\"total\": 1"), "{text}");
        let r = respond(
            &lib,
            &json!({"jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": {"name": "move_to_folder", "arguments": {"ids": ["web:x"], "folder": "Ders"}}}),
            true,
        );
        assert_eq!(r.as_ref().and_then(|r| r.pointer("/result/isError")), Some(&json!(true)));
        let r = respond(&lib, &json!({"jsonrpc": "2.0", "id": 5, "method": "resources/read", "params": {"uri": "wroopmark://item/web:yok"}}), true);
        assert!(r.as_ref().and_then(|r| r.get("error")).is_some());
        let id = handle_value(&lib, json!({"cmd": "search", "q": "istanbul"}));
        let id = id.pointer("/data/items/0/id").and_then(Value::as_str).unwrap_or("").to_string();
        let r =
            respond(&lib, &json!({"jsonrpc": "2.0", "id": 6, "method": "resources/read", "params": {"uri": format!("wroopmark://item/{id}")}}), true);
        let md = r.as_ref().and_then(|r| r.pointer("/result/contents/0/text")).and_then(Value::as_str).unwrap_or("");
        assert!(md.contains("Istanbul notları"), "{md}");
        let _ = std::fs::remove_dir_all(&dir);
    }
}
