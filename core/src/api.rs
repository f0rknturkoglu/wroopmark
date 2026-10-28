//! The library handle and its JSON command surface, shared by the FFI layer
//! (Swift apps), the CLI and the Chromium native-messaging host.
//!
//! Request:  `{"cmd": "search", "q": "tag:dev rust"}`
//! Response: `{"ok": true, "data": ...}` or `{"ok": false, "error": "..."}`

use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, MutexGuard};
use std::thread::JoinHandle;

use serde::Deserialize;
use serde_json::{Value, json};

use crate::db::{Saved, Store};
use crate::fetch::Fetcher;
use crate::media::MediaStore;
use crate::model::{Item, Media, MediaKind};
use crate::query::Query;
use crate::text::item_id_for_url;

pub const VERSION: &str = env!("CARGO_PKG_VERSION");

/// Appends a line to `<library>/host.log`, which shows what the browser
/// extensions saw and did (Chromium's host and Safari's handler alike).
/// Kept under ~512 KB by starting over.
pub fn append_log(root: &Path, line: &str) {
    use std::io::Write;
    let path = root.join("host.log");
    if std::fs::metadata(&path).map(|m| m.len() > 512 * 1024).unwrap_or(false) {
        let _ = std::fs::remove_file(&path);
    }
    let _ = std::fs::create_dir_all(root);
    if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(&path) {
        let _ = writeln!(f, "{} {line}", chrono::Local::now().format("%Y-%m-%d %H:%M:%S"));
    }
}

pub struct Library {
    root: PathBuf,
    store: Mutex<Store>,
    pub media: MediaStore,
    fetcher: Fetcher,
    worker: Mutex<Option<JoinHandle<()>>>,
}

#[derive(Debug, Default, serde::Serialize)]
pub struct ImportReport {
    pub new: usize,
    pub updated: usize,
    pub ids: Vec<String>,
}

impl Library {
    /// `$WROOPMARK_HOME`, else `~/Library/Application Support/wroopmark`.
    pub fn default_root() -> PathBuf {
        if let Some(p) = std::env::var_os("WROOPMARK_HOME") {
            return PathBuf::from(p);
        }
        let home = std::env::var_os("HOME").map(PathBuf::from).unwrap_or_else(|| PathBuf::from("."));
        home.join("Library/Application Support/wroopmark")
    }

    pub fn open(root: &Path) -> Result<Arc<Self>, String> {
        std::fs::create_dir_all(root).map_err(|e| format!("{}: {e}", root.display()))?;
        let store = Store::open(&root.join("library.sqlite")).map_err(|e| e.to_string())?;
        Ok(Arc::new(Self {
            root: root.to_path_buf(),
            store: Mutex::new(store),
            media: MediaStore::new(root.join("media")),
            fetcher: Fetcher::new(),
            worker: Mutex::new(None),
        }))
    }

    pub fn root(&self) -> &Path {
        &self.root
    }

    /// The store lock. A panic while holding it does not brick the library.
    pub fn store(&self) -> MutexGuard<'_, Store> {
        self.store.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// Saves a batch in one transaction: all of it or nothing.
    fn save_all(&self, items: Vec<Item>, tags: &[String]) -> Result<ImportReport, String> {
        let items: Vec<Item> = items
            .into_iter()
            .map(|mut item| {
                if item.id.is_empty() {
                    let (platform, id) = item_id_for_url(&item.url);
                    item.platform = platform;
                    item.id = id;
                }
                item.tags.extend(tags.iter().cloned());
                item
            })
            .collect();
        let mut report = ImportReport::default();
        for Saved { id, created } in self.store().upsert_all(&items).map_err(|e| e.to_string())? {
            if created {
                report.new += 1
            } else {
                report.updated += 1
            }
            report.ids.push(id);
        }
        Ok(report)
    }

    /// Captures a URL from the network and saves it with its media.
    pub fn add_url(&self, url: &str, tags: &[String], note: Option<&str>) -> Result<Item, String> {
        let mut item = self.fetcher.capture(url)?;
        item.note = note.map(str::to_string);
        self.fetcher.fill_media(&self.media, &mut item.media, self.videos_enabled());
        let report = self.save_all(vec![item.clone()], tags)?;
        let id = &report.ids[0];
        self.store().set_media(id, &item.media, None).map_err(|e| e.to_string())?;
        self.store().get(id).map_err(|e| e.to_string())?.ok_or_else(|| "kaydedilemedi".into())
    }

    /// Saves every tweet in an x.com GraphQL response.
    pub fn import_x(&self, payload: &Value, tags: &[String]) -> Result<ImportReport, String> {
        // Timelines list newest first; saving oldest first keeps that order
        // among items that end up with the same save time.
        let mut items = crate::x::parse_timeline(payload);
        items.reverse();
        let mut report = self.save_all(items, tags)?;
        report.ids.reverse();
        Ok(report)
    }

    /// Saves every TikTok item in a TikTok web API response (favorites, …).
    pub fn import_tiktok(&self, payload: &Value, tags: &[String]) -> Result<ImportReport, String> {
        self.save_all(crate::tiktok::parse_api(payload), tags)
    }

    /// Saves items already shaped by a capturer (extensions, share sheet).
    pub fn import_items(&self, items: Vec<Item>, tags: &[String]) -> Result<ImportReport, String> {
        self.save_all(items, tags)
    }

    /// Videos are downloaded unless turned off in the settings.
    pub fn videos_enabled(&self) -> bool {
        self.store().setting("download_videos").ok().flatten().is_none_or(|v| v != "0")
    }

    pub fn set_videos_enabled(self: &Arc<Self>, on: bool) -> Result<(), String> {
        let mut store = self.store();
        store.set_setting("download_videos", if on { "1" } else { "0" }).map_err(|e| e.to_string())?;
        if on {
            store.queue_videos().map_err(|e| e.to_string())?;
            drop(store);
            self.kick_media();
        }
        Ok(())
    }

    /// Points media at files already on disk for the same URL (the same
    /// picture in another post), so only new things hit the network.
    fn reuse_known_files(&self, media: &mut [Media]) {
        let store = self.store();
        for m in media.iter_mut() {
            if m.file.is_none() {
                let src = m.local_source().to_string();
                m.file = store.known_file(&src).ok().flatten().filter(|f| self.media.contains(f));
            }
            if m.video_file.is_none() && m.kind != MediaKind::Image {
                m.video_file = store.known_file(&m.url).ok().flatten().filter(|f| self.media.contains(f));
            }
        }
    }

    fn fill_item(&self, item: &mut Item, videos: bool) -> usize {
        self.reuse_known_files(&mut item.media);
        if let Some(q) = item.quote.as_mut() {
            self.reuse_known_files(&mut q.media);
        }
        let mut files = self.fetcher.fill_media(&self.media, &mut item.media, videos);
        if let Some(q) = item.quote.as_mut() {
            files += self.fetcher.fill_media(&self.media, &mut q.media, videos);
        }
        files
    }

    /// Downloads media for up to `limit` pending items and returns how many
    /// items were processed. The store lock is released during downloads.
    pub fn fetch_pending_media(&self, limit: i64) -> Result<usize, String> {
        let pending = self.store().pending_media(limit).map_err(|e| e.to_string())?;
        let videos = self.videos_enabled();
        for item in &pending {
            let mut item = item.clone();
            self.fill_item(&mut item, videos);
            self.store().set_media(&item.id, &item.media, item.quote.as_deref()).map_err(|e| e.to_string())?;
        }
        Ok(pending.len())
    }

    /// Which of these items still lack their video file.
    pub fn videos_needed(&self, ids: &[String]) -> Result<Vec<String>, String> {
        if !self.videos_enabled() {
            return Ok(vec![]);
        }
        let store = self.store();
        let mut out = vec![];
        for id in ids {
            if let Some(item) = store.get(id).map_err(|e| e.to_string())?.filter(Self::needs_video) {
                out.push(item.id);
            }
        }
        Ok(out)
    }

    fn needs_video(item: &Item) -> bool {
        item.media.iter().any(|m| m.kind != MediaKind::Image && m.video_file.is_none())
    }

    /// Receives a video the browser extension downloaded inside the site
    /// (TikTok only serves video files to its own pages), in base64 chunks.
    /// Chunks go to a file under the library so any process can take the
    /// next one (Safari may start a fresh extension process per message).
    /// `offset` (bytes sent before this chunk) and, on the last one, `size`
    /// catch a lost or repeated chunk; the file is then dropped, not saved.
    pub fn upload_chunk(&self, c: &Chunk) -> Result<Option<Item>, String> {
        use base64::Engine;
        use std::io::Write;
        const MAX: u64 = 600 << 20;
        let dir = self.root.join(".uploads");
        std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
        let safe: String = c.id.chars().map(|c| if c.is_ascii_alphanumeric() { c } else { '_' }).collect();
        let part = dir.join(format!("{safe}.part"));
        let fail = |e: String| {
            let _ = std::fs::remove_file(&part);
            Err(e)
        };
        if c.seq == 0 && !self.store().get(&c.id).map_err(|e| e.to_string())?.is_some_and(|i| Self::needs_video(&i)) {
            return Err("bu kaydın beklenen bir videosu yok".into());
        }
        let have = if c.seq == 0 { 0 } else { std::fs::metadata(&part).map(|m| m.len()).unwrap_or(0) };
        if c.offset.is_some_and(|o| o != have) || (c.seq > 0 && have == 0) {
            return fail(format!("parça sırası bozuk: {} bayt var, {} bekleniyordu", have, c.offset.unwrap_or(0)));
        }
        let bytes = base64::engine::general_purpose::STANDARD.decode(&c.data).map_err(|e| format!("geçersiz parça: {e}"))?;
        let (seq, last) = (c.seq, c.last);
        let mut f = std::fs::OpenOptions::new().create(true).write(true).append(seq > 0).truncate(seq == 0).open(&part).map_err(|e| e.to_string())?;
        f.write_all(&bytes).map_err(|e| e.to_string())?;
        let len = f.metadata().map(|m| m.len()).unwrap_or(0);
        if len > MAX {
            return fail("video çok büyük".into());
        }
        if !last {
            return Ok(None);
        }
        drop(f);
        if c.size.is_some_and(|s| s != len) {
            return fail(format!("video eksik geldi: {len} / {} bayt", c.size.unwrap_or(0)));
        }
        // Checked again: another process may have saved it meanwhile.
        let item = self.store().get(&c.id).map_err(|e| e.to_string())?.filter(Self::needs_video);
        let Some(mut item) = item else { return fail("bu kaydın beklenen bir videosu yok".into()) };
        let reader = std::fs::File::open(&part).map_err(|e| e.to_string())?;
        let name = self.media.put_reader(reader, &c.content_type).map_err(|e| e.to_string());
        let _ = std::fs::remove_file(&part);
        let name = name?;
        if let Some(m) = item.media.iter_mut().find(|m| m.kind != MediaKind::Image && m.video_file.is_none()) {
            m.video_file = Some(name);
        }
        let mut store = self.store();
        store.set_media(&c.id, &item.media, item.quote.as_deref()).map_err(|e| e.to_string())?;
        store.get(&c.id).map_err(|e| e.to_string())
    }

    /// Downloads everything one item has, videos included, right now.
    pub fn download_item(&self, id: &str) -> Result<Item, String> {
        let mut item = self.store().get(id).map_err(|e| e.to_string())?.ok_or("kayıt yok")?;
        self.fill_item(&mut item, true);
        let mut store = self.store();
        store.set_media(id, &item.media, item.quote.as_deref()).map_err(|e| e.to_string())?;
        store.get(id).map_err(|e| e.to_string())?.ok_or_else(|| "kayıt yok".into())
    }

    /// Starts a background media download pass unless one is running.
    pub fn kick_media(self: &Arc<Self>) {
        let mut slot = self.worker.lock().unwrap_or_else(|e| e.into_inner());
        if slot.as_ref().is_some_and(|h| !h.is_finished()) {
            return;
        }
        let lib = Arc::clone(self);
        *slot = Some(std::thread::spawn(move || while matches!(lib.fetch_pending_media(10), Ok(n) if n > 0) {}));
    }

    /// Blocks until the background media pass (if any) is done.
    pub fn wait_media(&self) {
        let handle = self.worker.lock().unwrap_or_else(|e| e.into_inner()).take();
        if let Some(h) = handle {
            let _ = h.join();
        }
    }

    /// Fetches titles/descriptions for links that have none yet. A page that
    /// cannot be fetched is not marked done; it is tried again later.
    pub fn enrich_links(&self, limit: i64) -> Result<usize, String> {
        let todo = self.store().links_to_enrich(limit).map_err(|e| e.to_string())?;
        let n = todo.len();
        for (id, url) in todo {
            let saved = match self.fetcher.page(&url) {
                Ok(meta) => self.store().set_link_meta(id, meta.title.as_deref(), meta.description.as_deref(), meta.image.as_deref()),
                Err(_) => self.store().link_fetch_failed(id),
            };
            saved.map_err(|e| e.to_string())?;
        }
        Ok(n)
    }

    pub fn delete(&self, id: &str) -> Result<usize, String> {
        let orphans = self.store().delete(id).map_err(|e| e.to_string())?;
        orphans.iter().for_each(|f| self.media.remove(f));
        Ok(orphans.len())
    }
}

#[derive(Deserialize)]
struct Id {
    id: String,
}

#[derive(Deserialize)]
struct LinkId {
    id: i64,
}

#[derive(Deserialize)]
struct Page {
    #[serde(default)]
    q: String,
    #[serde(default = "default_limit")]
    limit: i64,
    #[serde(default)]
    offset: i64,
}

fn default_limit() -> i64 {
    50
}

#[derive(Deserialize)]
struct AddUrl {
    url: String,
    #[serde(default)]
    tags: Vec<String>,
    note: Option<String>,
}

#[derive(Deserialize)]
struct ImportPayload {
    /// A platform API response, as an object or as the raw response text.
    payload: Value,
    #[serde(default)]
    tags: Vec<String>,
}

#[derive(Deserialize)]
struct ImportItems {
    items: Vec<Item>,
    #[serde(default)]
    tags: Vec<String>,
}

#[derive(Deserialize)]
struct SetTags {
    id: String,
    tags: Vec<String>,
}

#[derive(Deserialize)]
struct EditTags {
    ids: Vec<String>,
    #[serde(default)]
    add: Vec<String>,
    #[serde(default)]
    remove: Vec<String>,
}

#[derive(Deserialize)]
struct RenameTag {
    from: String,
    to: String,
}

#[derive(Deserialize)]
struct SetNote {
    id: String,
    note: Option<String>,
}

#[derive(Deserialize)]
struct SetExtra {
    id: String,
    text: String,
}

#[derive(Deserialize)]
struct Url {
    url: String,
}

#[derive(Deserialize)]
struct Limit {
    #[serde(default = "default_limit")]
    limit: i64,
}

#[derive(Deserialize)]
struct File {
    file: String,
}

/// One piece of a video upload (see [`Library::upload_chunk`]).
#[derive(Deserialize)]
pub struct Chunk {
    pub id: String,
    pub seq: u64,
    pub data: String,
    #[serde(default)]
    pub last: bool,
    #[serde(default)]
    pub content_type: String,
    /// Bytes already sent before this chunk.
    pub offset: Option<u64>,
    /// Total bytes, on the last chunk.
    pub size: Option<u64>,
}

pub fn handle(lib: &Arc<Library>, raw: &str) -> Value {
    match serde_json::from_str::<Value>(raw) {
        Ok(req) => handle_value(lib, req),
        Err(e) => json!({ "ok": false, "error": format!("geçersiz JSON: {e}") }),
    }
}

pub fn handle_value(lib: &Arc<Library>, req: Value) -> Value {
    match dispatch(lib, req) {
        Ok(data) => json!({ "ok": true, "data": data }),
        Err(e) => json!({ "ok": false, "error": e }),
    }
}

fn arg<T: for<'de> Deserialize<'de>>(req: Value) -> Result<T, String> {
    serde_json::from_value(req).map_err(|e| format!("geçersiz istek: {e}"))
}

fn to_value<T: serde::Serialize>(v: T) -> Result<Value, String> {
    serde_json::to_value(v).map_err(|e| e.to_string())
}

fn dispatch(lib: &Arc<Library>, req: Value) -> Result<Value, String> {
    let cmd = req.get("cmd").and_then(Value::as_str).ok_or("cmd eksik")?.to_string();
    let db = |e: rusqlite::Error| e.to_string();

    match cmd.as_str() {
        "ping" => Ok(json!({ "version": VERSION, "library": lib.root() })),
        "log" => {
            // One line per entry: control characters cannot forge others.
            let line: String =
                req.get("line").and_then(Value::as_str).unwrap_or("").chars().take(500).map(|c| if c.is_control() { ' ' } else { c }).collect();
            append_log(lib.root(), &format!("eklenti: {line}"));
            Ok(json!(true))
        }
        "stats" => {
            let mut v = to_value(lib.store().stats().map_err(db)?)?;
            v["media_bytes"] = json!(lib.media.bytes());
            Ok(v)
        }
        "settings" => Ok(json!({ "download_videos": lib.videos_enabled() })),
        "set_settings" => {
            if let Some(on) = req.get("download_videos").and_then(Value::as_bool) {
                lib.set_videos_enabled(on)?;
            }
            Ok(json!({ "download_videos": lib.videos_enabled() }))
        }
        "videos_needed" => {
            #[derive(Deserialize)]
            struct Ids {
                ids: Vec<String>,
            }
            to_value(lib.videos_needed(&arg::<Ids>(req)?.ids)?)
        }
        "upload_chunk" => to_value(lib.upload_chunk(&arg::<Chunk>(req)?)?),
        "download_media" => to_value(lib.download_item(&arg::<Id>(req)?.id)?),
        "data_version" => to_value(lib.store().data_version().map_err(db)?),
        // Folds the WAL into the main file; the app sends it when quitting.
        "checkpoint" => {
            lib.store().checkpoint();
            Ok(json!(true))
        }

        "add_url" => {
            let a: AddUrl = arg(req)?;
            to_value(lib.add_url(&a.url, &a.tags, a.note.as_deref())?)
        }
        "import_x" | "import_tiktok" => {
            let a: ImportPayload = arg(req)?;
            let payload = match a.payload {
                Value::String(s) => serde_json::from_str(&s).map_err(|e| format!("payload JSON değil: {e}"))?,
                v => v,
            };
            let report = if cmd == "import_x" { lib.import_x(&payload, &a.tags)? } else { lib.import_tiktok(&payload, &a.tags)? };
            lib.kick_media();
            to_value(report)
        }
        "import_items" => {
            let a: ImportItems = arg(req)?;
            let report = lib.import_items(a.items, &a.tags)?;
            lib.kick_media();
            to_value(report)
        }

        "search" => {
            let p: Page = arg(req)?;
            to_value(lib.store().search(&Query::parse(&p.q), p.limit.clamp(1, 500), p.offset.max(0)).map_err(db)?)
        }
        "get" => to_value(lib.store().get(&arg::<Id>(req)?.id).map_err(db)?),
        "raw" => to_value(lib.store().raw(&arg::<Id>(req)?.id).map_err(db)?),
        "delete" => to_value(lib.delete(&arg::<Id>(req)?.id)?),

        "tags" => to_value(lib.store().tags().map_err(db)?),
        "set_tags" => {
            let a: SetTags = arg(req)?;
            lib.store().set_tags(&a.id, &a.tags).map_err(db)?;
            Ok(json!(true))
        }
        "edit_tags" => {
            let a: EditTags = arg(req)?;
            lib.store().edit_tags(&a.ids, &a.add, &a.remove).map_err(db)?;
            Ok(json!(true))
        }
        "rename_tag" => {
            let a: RenameTag = arg(req)?;
            to_value(lib.store().rename_tag(&a.from, &a.to).map_err(db)?)
        }
        "set_note" => {
            let a: SetNote = arg(req)?;
            lib.store().set_note(&a.id, a.note.as_deref()).map_err(db)?;
            Ok(json!(true))
        }
        "ocr_pending" => {
            let limit = arg::<Limit>(req)?.limit;
            let rows = lib.store().ocr_pending(limit).map_err(db)?;
            let paths: Vec<Value> = rows
                .into_iter()
                .map(|(id, files)| json!({ "id": id, "files": files.iter().map(|f| lib.media.path(f)).collect::<Vec<_>>() }))
                .collect();
            Ok(json!(paths))
        }
        "set_ocr" => {
            let a: SetExtra = arg(req)?;
            lib.store().set_ocr(&a.id, &a.text).map_err(db)?;
            Ok(json!(true))
        }
        "set_extra" => {
            let a: SetExtra = arg(req)?;
            lib.store().set_extra(&a.id, &a.text).map_err(db)?;
            Ok(json!(true))
        }

        "links" => {
            let p: Page = arg(req)?;
            to_value(lib.store().links(&p.q, p.limit.clamp(1, 500), p.offset.max(0)).map_err(db)?)
        }
        "link_items" => to_value(lib.store().link_items(arg::<LinkId>(req)?.id).map_err(db)?),
        "add_link" => to_value(lib.store().add_link(&arg::<Url>(req)?.url).map_err(db)?.ok_or("geçersiz URL")?),
        "delete_link" => {
            lib.store().delete_link(arg::<LinkId>(req)?.id).map_err(db)?;
            Ok(json!(true))
        }
        "enrich_links" => to_value(lib.enrich_links(arg::<Limit>(req)?.limit)?),

        // Short-lived capturers (the Safari extension process) may die before
        // their downloads finish; the app picks the queue up with this.
        "kick_media" => {
            lib.kick_media();
            Ok(json!(true))
        }
        "fetch_media" => to_value(lib.fetch_pending_media(arg::<Limit>(req)?.limit)?),
        "retry_media" => {
            let n = lib.store().retry_media().map_err(db)?;
            lib.kick_media();
            to_value(n)
        }
        "media_path" => {
            let file = arg::<File>(req)?.file;
            if !crate::media::is_name(&file) {
                return Err(format!("geçersiz dosya adı: {file}"));
            }
            Ok(json!(lib.media.path(&file)))
        }

        other => Err(format!("bilinmeyen komut: {other}")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn json_surface() {
        let dir = std::env::temp_dir().join(format!("wm-api-{}", std::process::id()));
        let lib = Library::open(&dir).unwrap();
        let r = handle(
            &lib,
            r#"{"cmd":"import_items","tags":["deneme"],"items":[{"platform":"web","url":"https://example.com/a?utm_source=x","text":"Merhaba dünya"}]}"#,
        );
        assert_eq!(r["ok"], true, "{r}");
        assert_eq!(r["data"]["new"], 1);
        let r = handle(&lib, r#"{"cmd":"search","q":"DÜNYA tag:deneme"}"#);
        assert_eq!(r["data"]["total"], 1, "{r}");
        assert_eq!(r["data"]["items"][0]["tags"][0], "deneme");
        // A video arriving from the extension in two chunks.
        let r = handle(
            &lib,
            r#"{"cmd":"import_items","items":[{"url":"https://www.tiktok.com/@a/video/77","media":[{"kind":"video","url":"https://www.tiktok.com/@a/video/77"}]}]}"#,
        );
        assert_eq!(r["data"]["ids"][0], "tiktok:77", "{r}");
        assert_eq!(handle(&lib, r#"{"cmd":"videos_needed","ids":["tiktok:77"]}"#)["data"][0], "tiktok:77");
        // "\0\0\0\x18ftypmp42" + "rest", base64 in two parts
        assert_eq!(handle(&lib, r#"{"cmd":"upload_chunk","id":"tiktok:77","seq":0,"data":"AAAAGGZ0eXBtcDQy"}"#)["ok"], true);
        let r = handle(&lib, r#"{"cmd":"upload_chunk","id":"tiktok:77","seq":1,"data":"cmVzdA==","last":true,"content_type":"video/mp4"}"#);
        assert!(r["data"]["media"][0]["video_file"].as_str().unwrap().ends_with(".mp4"), "{r}");
        assert_eq!(handle(&lib, r#"{"cmd":"videos_needed","ids":["tiktok:77"]}"#)["data"].as_array().unwrap().len(), 0);
        // Nothing waits for a video any more: a new upload is refused.
        assert_eq!(handle(&lib, r#"{"cmd":"upload_chunk","id":"tiktok:77","seq":0,"data":"AAAA"}"#)["ok"], false);
        // A chunk out of order drops the upload instead of saving a broken file.
        handle(
            &lib,
            r#"{"cmd":"import_items","items":[{"url":"https://www.tiktok.com/@a/video/78","media":[{"kind":"video","url":"https://www.tiktok.com/@a/video/78"}]}]}"#,
        );
        assert_eq!(handle(&lib, r#"{"cmd":"upload_chunk","id":"tiktok:78","seq":0,"offset":0,"data":"AAAAGGZ0eXBtcDQy"}"#)["ok"], true);
        let r = handle(&lib, r#"{"cmd":"upload_chunk","id":"tiktok:78","seq":2,"offset":24,"data":"cmVzdA==","last":true}"#);
        assert_eq!(r["ok"], false, "{r}");
        let r = handle(&lib, r#"{"cmd":"upload_chunk","id":"tiktok:78","seq":0,"offset":0,"data":"AAAAGGZ0eXBtcDQy","last":true,"size":99}"#);
        assert_eq!(r["ok"], false, "{r}");
        assert_eq!(handle(&lib, r#"{"cmd":"videos_needed","ids":["tiktok:78"]}"#)["data"][0], "tiktok:78");
        assert_eq!(handle(&lib, r#"{"cmd":"media_path","file":"../../etc/passwd"}"#)["ok"], false);
        let r = handle(&lib, r#"{"cmd":"nope"}"#);
        assert_eq!(r["ok"], false);
        lib.wait_media();
        let _ = std::fs::remove_dir_all(dir);
    }
}
