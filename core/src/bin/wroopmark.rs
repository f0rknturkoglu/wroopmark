//! `wroopmark` — CLI over the core, and the Chromium native-messaging host.
//!
//! Chromium starts native hosts with the caller's origin as the first
//! argument (`chrome-extension://<id>/`); that switches this binary into host
//! mode: 4-byte little-endian length + JSON on stdin/stdout, one request per
//! message, same commands as `wroopmark call`.

use std::io::{self, Read, Write};
use std::path::PathBuf;
use std::sync::Arc;

use serde_json::{Value, json};
use wroopmark_core::api::{self, Library};
use wroopmark_core::model::Item;

const HELP: &str = "wroopmark — sosyal medya kayıt arşivi

kullanım: wroopmark [--lib DİZİN] <komut>

  add <url> [-t etiket]... [-n not]   URL'yi indir ve kaydet
  import-x <dosya.json>               x.com GraphQL cevabını içe aktar
  search <sorgu...>                   ara (tag:x from:@y platform:x has:image \"ifade\")
  show <id>                           tek kaydı göster (JSON)
  tag <id> <etiket>...                etiketleri değiştir
  tags                                etiketler ve sayıları
  rename-tag <eski> <yeni>            etiketi (alt etiketleriyle) yeniden adlandır
  rm <id>                             kaydı sil
  links [sorgu...] [--enrich]         link havuzu
  media [--retry]                     eksik medyayı indir
  stats                               özet
  call '<json>'                       ham API komutu

kütüphane: $WROOPMARK_HOME ya da ~/Library/Application Support/wroopmark";

fn main() {
    let mut args: Vec<String> = std::env::args().skip(1).collect();
    if args.first().is_some_and(|a| a.starts_with("chrome-extension://")) {
        std::process::exit(native_host());
    }
    let mut root = Library::default_root();
    if let Some(i) = args.iter().position(|a| a == "--lib") {
        if i + 1 >= args.len() {
            die("--lib bir dizin ister");
        }
        root = PathBuf::from(args.remove(i + 1));
        args.remove(i);
    }
    let Some(cmd) = args.first().cloned() else {
        println!("{HELP}");
        return;
    };
    let rest = &args[1..];
    let lib = Library::open(&root).unwrap_or_else(|e| die(&e));

    let result = match cmd.as_str() {
        "add" => cmd_add(&lib, rest),
        "import-x" => cmd_import_x(&lib, rest),
        "search" | "s" => cmd_search(&lib, rest),
        "show" => call(&lib, json!({ "cmd": "get", "id": need(rest, 0, "id") })).map(|v| pretty(&v)),
        "tag" => call(&lib, json!({ "cmd": "set_tags", "id": need(rest, 0, "id"), "tags": &rest[1..] })).map(|_| "tamam".into()),
        "tags" => cmd_tags(&lib),
        "rename-tag" => call(&lib, json!({ "cmd": "rename_tag", "from": need(rest, 0, "eski"), "to": need(rest, 1, "yeni") }))
            .map(|n| format!("{n} etiket yeniden adlandırıldı")),
        "rm" => call(&lib, json!({ "cmd": "delete", "id": need(rest, 0, "id") })).map(|n| format!("silindi ({n} medya dosyası)")),
        "links" => cmd_links(&lib, rest),
        "media" => cmd_media(&lib, rest),
        "stats" => call(&lib, json!({ "cmd": "stats" })).map(|v| pretty(&v)),
        "call" => {
            let req: Value = serde_json::from_str(&need(rest, 0, "json")).unwrap_or_else(|e| die(&format!("geçersiz JSON: {e}")));
            Ok(pretty(&api::handle_value(&lib, req)))
        }
        "help" | "-h" | "--help" => Ok(HELP.into()),
        other => Err(format!("bilinmeyen komut: {other}\n\n{HELP}")),
    };
    lib.wait_media();
    lib.store().checkpoint();
    match result {
        Ok(out) => println!("{out}"),
        Err(e) => die(&e),
    }
}

fn die(msg: &str) -> ! {
    eprintln!("hata: {msg}");
    std::process::exit(1);
}

fn need(args: &[String], i: usize, what: &str) -> String {
    args.get(i).cloned().unwrap_or_else(|| die(&format!("{what} eksik")))
}

fn pretty(v: &Value) -> String {
    serde_json::to_string_pretty(v).unwrap_or_default()
}

fn call(lib: &Arc<Library>, req: Value) -> Result<Value, String> {
    let r = api::handle_value(lib, req);
    if r["ok"] == true { Ok(r["data"].clone()) } else { Err(r["error"].as_str().unwrap_or("?").to_string()) }
}

/// Splits `-t tag` / `-n note` flags from positional args.
fn flags(args: &[String]) -> (Vec<String>, Vec<String>, Option<String>) {
    let (mut pos, mut tags, mut note) = (vec![], vec![], None);
    let mut it = args.iter();
    while let Some(a) = it.next() {
        match a.as_str() {
            "-t" | "--tag" => tags.extend(it.next().cloned()),
            "-n" | "--note" => note = it.next().cloned(),
            _ => pos.push(a.clone()),
        }
    }
    (pos, tags, note)
}

fn line(item: &Item) -> String {
    let who = item.author_handle.as_deref().map(|h| format!("@{h}")).or_else(|| item.author_name.clone()).unwrap_or_default();
    let body = item.title.as_deref().filter(|t| !t.is_empty()).unwrap_or(&item.text);
    let mut body: String = body.split_whitespace().collect::<Vec<_>>().join(" ");
    if body.chars().count() > 90 {
        body = body.chars().take(89).collect::<String>() + "…";
    }
    let media = if item.media.is_empty() { String::new() } else { format!(" [{}📎]", item.media.len()) };
    let tags = if item.tags.is_empty() { String::new() } else { format!("  #{}", item.tags.join(" #")) };
    format!("{:<28} {:<16} {body}{media}{tags}", item.id, who)
}

fn cmd_add(lib: &Arc<Library>, args: &[String]) -> Result<String, String> {
    let (pos, tags, note) = flags(args);
    let mut out = vec![];
    for url in pos {
        let v = call(lib, json!({ "cmd": "add_url", "url": url, "tags": tags, "note": note }))?;
        let item: Item = serde_json::from_value(v).map_err(|e| e.to_string())?;
        out.push(line(&item));
    }
    if out.is_empty() { Err("URL eksik".into()) } else { Ok(out.join("\n")) }
}

fn cmd_import_x(lib: &Arc<Library>, args: &[String]) -> Result<String, String> {
    let (pos, tags, _) = flags(args);
    let mut total = (0, 0);
    for path in pos {
        let text = std::fs::read_to_string(&path).map_err(|e| format!("{path}: {e}"))?;
        let payload: Value = serde_json::from_str(&text).map_err(|e| format!("{path}: {e}"))?;
        let r = call(lib, json!({ "cmd": "import_x", "payload": payload, "tags": tags }))?;
        total.0 += r["new"].as_u64().unwrap_or(0);
        total.1 += r["updated"].as_u64().unwrap_or(0);
    }
    eprintln!("medya indiriliyor…");
    Ok(format!("{} yeni, {} güncellendi", total.0, total.1))
}

fn cmd_search(lib: &Arc<Library>, args: &[String]) -> Result<String, String> {
    let mut v = call(lib, json!({ "cmd": "search", "q": args.join(" "), "limit": 30 }))?;
    let items_val = v.get_mut("items").map(Value::take).unwrap_or(Value::Null);
    let items: Vec<Item> = serde_json::from_value(items_val).map_err(|e| e.to_string())?;
    let mut out: Vec<String> = items.iter().map(line).collect();
    out.push(format!("— {} kayıt", v["total"]));
    if let Some(links) = v["links"].as_array().filter(|l| !l.is_empty()) {
        out.push(format!("— {} link:", links.len()));
        out.extend(links.iter().map(|l| format!("  {}  {}", l["url"].as_str().unwrap_or(""), l["title"].as_str().unwrap_or(""))));
    }
    Ok(out.join("\n"))
}

fn cmd_tags(lib: &Arc<Library>) -> Result<String, String> {
    let v = call(lib, json!({ "cmd": "tags" }))?;
    let rows = v.as_array().cloned().unwrap_or_default();
    Ok(rows.iter().map(|t| format!("{:>5}  {}", t["count"], t["name"].as_str().unwrap_or(""))).collect::<Vec<_>>().join("\n"))
}

fn cmd_links(lib: &Arc<Library>, args: &[String]) -> Result<String, String> {
    if args.iter().any(|a| a == "--enrich") {
        let n = call(lib, json!({ "cmd": "enrich_links", "limit": 100 }))?;
        eprintln!("{n} link zenginleştirildi");
    }
    let q: Vec<&str> = args.iter().filter(|a| *a != "--enrich").map(String::as_str).collect();
    let v = call(lib, json!({ "cmd": "links", "q": q.join(" "), "limit": 100 }))?;
    let rows = v.as_array().cloned().unwrap_or_default();
    Ok(rows
        .iter()
        .map(|l| format!("{:>3}× {}  {}", l["item_count"], l["url"].as_str().unwrap_or(""), l["title"].as_str().unwrap_or("")))
        .collect::<Vec<_>>()
        .join("\n"))
}

fn cmd_media(lib: &Arc<Library>, args: &[String]) -> Result<String, String> {
    if args.iter().any(|a| a == "--retry") {
        call(lib, json!({ "cmd": "retry_media" }))?;
    }
    let mut n = 0;
    loop {
        let got = call(lib, json!({ "cmd": "fetch_media", "limit": 5 }))?.as_u64().unwrap_or(0);
        if got == 0 {
            break;
        }
        n += got;
        eprint!("\r{n} kayıt");
    }
    Ok(format!("{n} kaydın medyası işlendi"))
}

const MAX_REQUEST: usize = 64 << 20;

/// Chromium native-messaging loop. Runs until the extension disconnects,
/// then lets any background media downloads finish.
fn native_host() -> i32 {
    let root = Library::default_root();
    host_log(&root, &format!("başladı: {}", std::env::args().nth(1).unwrap_or_default()));
    let lib = match Library::open(&root) {
        Ok(l) => l,
        Err(e) => {
            host_log(&root, &format!("kütüphane açılamadı: {e}"));
            let _ = write_msg(&json!({ "ok": false, "error": e }));
            return 1;
        }
    };
    let mut stdin = io::stdin().lock();
    loop {
        let mut len = [0u8; 4];
        if stdin.read_exact(&mut len).is_err() {
            break;
        }
        // The extension's largest messages are a page of TikTok items or a
        // video chunk (~2 MB); a length far beyond that is a broken stream.
        let len = u32::from_le_bytes(len) as usize;
        if len > MAX_REQUEST {
            host_log(&root, &format!("istek çok büyük ({len} bayt), bağlantı kapatılıyor"));
            let _ = write_msg(&json!({ "ok": false, "error": "istek çok büyük" }));
            break;
        }
        let mut buf = vec![0u8; len];
        if stdin.read_exact(&mut buf).is_err() {
            break;
        }
        let resp = match serde_json::from_slice::<Value>(&buf) {
            Ok(req) => {
                let reply_to = req.get("rid").cloned();
                let cmd = req.get("cmd").and_then(Value::as_str).unwrap_or("?").to_string();
                let mut r = api::handle_value(&lib, req);
                match r.get("error").and_then(Value::as_str) {
                    Some(err) => host_log(&root, &format!("{cmd}: HATA {err}")),
                    // Asked on every page load (the "saved" badge): not logged.
                    None if matches!(cmd.as_str(), "lookup_url" | "folders") => {}
                    None => host_log(&root, &format!("{cmd}: {}", summary(&r["data"]))),
                }
                if let Some(rid) = reply_to {
                    r["rid"] = rid;
                }
                r
            }
            Err(e) => json!({ "ok": false, "error": format!("geçersiz JSON: {e}") }),
        };
        // Chromium rejects host messages over 1 MB.
        let mut bytes = serde_json::to_vec(&resp).unwrap_or_default();
        if bytes.len() > 1_000_000 {
            let rid = resp.get("rid").cloned();
            let fallback = json!({ "ok": false, "error": "yanıt çok büyük", "rid": rid });
            bytes = serde_json::to_vec(&fallback).unwrap_or_default();
        }
        if write_raw_msg(&bytes).is_err() {
            break;
        }
    }
    host_log(&root, "bağlantı kapandı");
    lib.wait_media();
    lib.store().checkpoint();
    0
}

/// One line per request in `<library>/host.log`.
fn host_log(root: &std::path::Path, line: &str) {
    api::append_log(root, line);
}

/// Short description of a response payload for the log.
fn summary(data: &Value) -> String {
    match data {
        Value::Object(m) if m.contains_key("new") => format!("{} yeni, {} güncellendi", m["new"], m["updated"]),
        Value::Object(m) if m.contains_key("total") => format!("{} sonuç", m["total"]),
        Value::Object(m) if m.contains_key("id") => format!("{}", m["id"]),
        Value::Array(a) => format!("{} satır", a.len()),
        other => other.to_string().chars().take(80).collect(),
    }
}

fn write_msg(v: &Value) -> io::Result<()> {
    let bytes = serde_json::to_vec(v)?;
    write_raw_msg(&bytes)
}

fn write_raw_msg(bytes: &[u8]) -> io::Result<()> {
    let len: u32 = u32::try_from(bytes.len()).map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;
    let mut out = io::stdout().lock();
    out.write_all(&len.to_le_bytes())?;
    out.write_all(bytes)?;
    out.flush()
}
