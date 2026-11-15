//! Sync between devices through a shared folder (iCloud Drive, Syncthing…).
//!
//! ```text
//! <folder>/
//!   ops/<device>/<YYYY-MM>.jsonl   each device appends only to its own files
//!   media/<ab>/<hash>.<ext>        pictures (and, if chosen, videos)
//!   devices/<device>.json          name and last sync, for the settings
//! ```
//!
//! The SQLite file never goes into the folder (two writers would corrupt
//! it). A device writes its changes as log lines (`SyncOp`, one per item,
//! only the field groups that changed) and reads the other devices' new
//! lines from where it stopped last time. Per field group, the newest
//! write wins (time, then device id), so concurrent edits of different
//! things both survive.

use std::fs::{self, File, OpenOptions};
use std::io::{Read, Seek, SeekFrom, Write as _};

use serde::Serialize;
use serde_json::{Value, json};

use super::*;
use crate::db::SyncOp;

#[derive(Debug, Default, Serialize)]
pub struct SyncReport {
    /// Log lines written by this device.
    pub pushed: usize,
    /// Lines read from other devices, and how many of those changed something.
    pub pulled: usize,
    pub applied: usize,
    pub media_out: usize,
    pub media_in: usize,
    /// Another sync (app, CLI) was already running.
    pub busy: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum MediaMode {
    None,
    Images,
    All,
}

impl MediaMode {
    fn parse(s: &str) -> Self {
        match s {
            "none" => Self::None,
            "all" => Self::All,
            _ => Self::Images,
        }
    }
}

fn now_ms() -> i64 {
    chrono::Utc::now().timestamp_millis()
}

fn newer(ts: i64, dev: &str, have: Option<&(i64, String)>) -> bool {
    match have {
        None => true,
        Some((t, d)) => (ts, dev) > (*t, d.as_str()),
    }
}

impl Library {
    fn sync_base(&self) -> Result<Option<PathBuf>> {
        Ok(self.lock_store()?.setting("sync_dir")?.filter(|d| !d.is_empty()).map(PathBuf::from))
    }

    /// This library's device id (made once, kept in the library).
    pub fn device_id(&self) -> Result<String> {
        let mut store = self.lock_store()?;
        if let Some(id) = store.setting("device_id")? {
            return Ok(id);
        }
        let seed = format!("{}-{}-{}", self.root.display(), std::process::id(), chrono::Utc::now().timestamp_nanos_opt().unwrap_or_default());
        let id = hash_hex(seed.as_bytes()).chars().take(16).collect::<String>();
        store.set_setting("device_id", &id)?;
        Ok(id)
    }

    fn media_mode(&self) -> Result<MediaMode> {
        Ok(MediaMode::parse(&self.lock_store()?.setting("sync_media")?.unwrap_or_default()))
    }

    /// Starts syncing with `dir` (made if missing). The first sync sends the
    /// whole library and takes everything the other devices have.
    pub fn sync_enable(self: &Arc<Self>, dir: &Path, name: Option<&str>, media: Option<&str>) -> Result<SyncReport> {
        let io = |source: std::io::Error| CoreError::IoPath { path: dir.display().to_string(), source };
        if dir.starts_with(&self.root) {
            return Err(CoreError::BackupInsideLibrary);
        }
        fs::create_dir_all(dir.join("ops")).map_err(io)?;
        fs::create_dir_all(dir.join("devices")).map_err(io)?;
        let id = self.device_id()?;
        {
            let mut store = self.lock_store()?;
            store.set_setting("sync_dir", &dir.display().to_string())?;
            if let Some(n) = name.filter(|n| !n.trim().is_empty()) {
                store.set_setting("device_name", n.trim())?;
            }
            if let Some(m) = media {
                store.set_setting("sync_media", m)?;
            }
            store.set_sync_enabled(true)?;
        }
        append_log(&self.root, &format!("senkron açıldı: {} (cihaz {id})", dir.display()));
        self.sync_now()
    }

    pub fn sync_disable(&self) -> Result<()> {
        let mut store = self.lock_store()?;
        store.set_sync_enabled(false)?;
        store.set_setting("sync_dir", "")?;
        Ok(())
    }

    /// Writes this device's changes, then applies the others'. Safe to call
    /// often: with nothing new it only lists a few files.
    pub fn sync_now(self: &Arc<Self>) -> Result<SyncReport> {
        let Some(base) = self.sync_base()? else { return Ok(SyncReport::default()) };
        if !self.lock_store()?.sync_enabled()? {
            return Ok(SyncReport::default());
        }
        // One sync at a time across processes (app, CLI, extension host).
        let lock_path = self.root.join("sync.lock");
        let lock = File::create(&lock_path).map_err(|source| CoreError::IoPath { path: lock_path.display().to_string(), source })?;
        if lock.try_lock().is_err() {
            return Ok(SyncReport { busy: true, ..Default::default() });
        }
        let dev = self.device_id()?;
        let mut report = SyncReport::default();
        self.push(&base, &dev, &mut report)?;
        self.pull(&base, &dev, &mut report)?;
        let name = self.lock_store()?.setting("device_name")?.unwrap_or_else(|| dev.clone());
        let info = json!({"id": dev, "name": name, "last_sync": crate::text::now(), "version": VERSION});
        let _ = fs::write(base.join("devices").join(format!("{dev}.json")), serde_json::to_vec_pretty(&info)?);
        let _ = lock.unlock();
        if report.applied > 0 || report.media_in > 0 {
            self.kick_media();
        }
        Ok(report)
    }

    fn push(&self, base: &Path, dev: &str, report: &mut SyncReport) -> Result<()> {
        let mode = self.media_mode()?;
        let dir = base.join("ops").join(dev);
        let io = |source: std::io::Error| CoreError::IoPath { path: dir.display().to_string(), source };
        fs::create_dir_all(&dir).map_err(io)?;
        // A crash while applying would leave tracking off for good.
        self.lock_store()?.set_applying(false)?;
        loop {
            let batch = self.lock_store()?.take_dirty(300)?;
            if batch.is_empty() {
                break;
            }
            let ts = now_ms();
            let file = dir.join(format!("{}.jsonl", chrono::Utc::now().format("%Y-%m")));
            let mut out = String::new();
            for (item, fields) in &batch {
                let op = if let Some(key) = item.strip_prefix("setting:") {
                    let value = self.lock_store()?.setting(key)?;
                    Some(SyncOp { ts, dev: dev.to_string(), setting: Some(key.to_string()), value, ..Default::default() })
                } else {
                    self.lock_store()?.sync_op(item, fields, ts, dev)?
                };
                let Some(op) = op else { continue };
                if let Some(c) = &op.content
                    && mode != MediaMode::None
                {
                    report.media_out += self.copy_media_out(base, c, mode);
                }
                out.push_str(&serde_json::to_string(&op)?);
                out.push('\n');
                report.pushed += 1;
            }
            let mut f = OpenOptions::new().create(true).append(true).open(&file).map_err(io)?;
            f.write_all(out.as_bytes()).map_err(io)?;
            f.sync_all().map_err(io)?;
            self.lock_store()?.sync_written(&batch, ts, dev)?;
        }
        Ok(())
    }

    fn copy_media_out(&self, base: &Path, item: &Item, mode: MediaMode) -> usize {
        let mut n = 0;
        let quote = item.quote.iter().flat_map(|q| q.media.iter());
        for m in item.media.iter().chain(quote) {
            let mut files = vec![m.file.as_deref()];
            if mode == MediaMode::All {
                files.push(m.video_file.as_deref());
            }
            for name in files.into_iter().flatten() {
                let src = self.media.path(name);
                let dst = base.join("media").join(name.get(..2).unwrap_or("00")).join(name);
                if src.is_file() && !dst.exists() {
                    if let Some(p) = dst.parent() {
                        let _ = fs::create_dir_all(p);
                    }
                    let tmp = dst.with_extension("part");
                    if fs::copy(&src, &tmp).is_ok() && fs::rename(&tmp, &dst).is_ok() {
                        n += 1;
                    }
                }
            }
        }
        n
    }

    /// Brings a remote item's files into the media store from the shared
    /// folder; files that are in neither stay empty and download as usual.
    fn take_media_in(&self, base: &Path, media: &mut [Media]) -> usize {
        let mut n = 0;
        for m in media {
            for slot in [&mut m.file, &mut m.video_file] {
                let Some(name) = slot.clone() else { continue };
                if self.media.contains(&name) {
                    continue;
                }
                let src = base.join("media").join(name.get(..2).unwrap_or("00")).join(&name);
                let dst = self.media.path(&name);
                let copied = src.is_file()
                    && dst.parent().is_some_and(|p| fs::create_dir_all(p).is_ok())
                    && fs::copy(&src, dst.with_extension("part")).is_ok()
                    && fs::rename(dst.with_extension("part"), &dst).is_ok();
                if copied {
                    n += 1;
                } else {
                    *slot = None;
                }
            }
        }
        n
    }

    fn pull(&self, base: &Path, dev: &str, report: &mut SyncReport) -> Result<()> {
        let ops_dir = base.join("ops");
        let Ok(devices) = fs::read_dir(&ops_dir) else { return Ok(()) };
        let mut lines: Vec<SyncOp> = vec![];
        let mut cursors: Vec<(String, u64)> = vec![];
        for d in devices.flatten() {
            let other = d.file_name().to_string_lossy().to_string();
            if other == dev || other.starts_with('.') || !d.path().is_dir() {
                continue;
            }
            let Ok(files) = fs::read_dir(d.path()) else { continue };
            let mut files: Vec<PathBuf> = files.flatten().map(|f| f.path()).filter(|p| p.extension().is_some_and(|e| e == "jsonl")).collect();
            files.sort();
            for path in files {
                let key = format!("{other}/{}", path.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default());
                let from = self.lock_store()?.cursor(&key)?;
                let Ok(mut f) = File::open(&path) else { continue };
                if f.metadata().map(|m| m.len() <= from).unwrap_or(true) || f.seek(SeekFrom::Start(from)).is_err() {
                    continue;
                }
                let mut buf = Vec::new();
                if f.read_to_end(&mut buf).is_err() {
                    continue;
                }
                // Only whole lines: the other device may be mid-write.
                let Some(end) = buf.iter().rposition(|&b| b == b'\n') else { continue };
                for line in buf.get(..=end).unwrap_or(&[]).split(|&b| b == b'\n') {
                    if line.is_empty() {
                        continue;
                    }
                    match serde_json::from_slice::<SyncOp>(line) {
                        Ok(op) => lines.push(op),
                        Err(e) => append_log(&self.root, &format!("senkron: okunamayan satır ({key}): {e}")),
                    }
                }
                cursors.push((key, from + end as u64 + 1));
            }
        }
        report.pulled = lines.len();
        if !lines.is_empty() {
            lines.sort_by(|a, b| (a.ts, &a.dev).cmp(&(b.ts, &b.dev)));
            self.lock_store()?.set_applying(true)?;
            let result = (|| -> Result<()> {
                for op in lines {
                    if self.apply_op(base, op, report)? {
                        report.applied += 1;
                    }
                }
                Ok(())
            })();
            self.lock_store()?.set_applying(false)?;
            result?;
        }
        let mut store = self.lock_store()?;
        for (key, off) in cursors {
            store.set_cursor(&key, off)?;
        }
        Ok(())
    }

    /// Applies the groups of one line that are newer than what we have.
    fn apply_op(&self, base: &Path, op: SyncOp, report: &mut SyncReport) -> Result<bool> {
        let (ts, dev) = (op.ts, op.dev.as_str());
        if let Some(key) = op.setting.as_deref() {
            let item = format!("setting:{key}");
            let mut store = self.lock_store()?;
            if key.starts_with("ui.") && newer(ts, dev, store.field_stamp(&item, "setting")?.as_ref()) {
                store.set_setting(key, op.value.as_deref().unwrap_or(""))?;
                store.stamp(&item, "setting", ts, dev)?;
                return Ok(true);
            }
            return Ok(false);
        }
        let Some(id) = op.id.clone() else { return Ok(false) };
        if op.deleted {
            let newest = self.lock_store()?.newest_stamp(&id)?;
            if !newer(ts, dev, newest.as_ref()) {
                return Ok(false);
            }
            self.delete(&id)?;
            self.lock_store()?.stamp(&id, "deleted", ts, dev)?;
            return Ok(true);
        }
        let mut changed = false;
        if let Some(mut item) = op.content {
            let have = self.lock_store()?.field_stamp(&id, "content")?;
            let deleted = self.lock_store()?.field_stamp(&id, "deleted")?;
            if newer(ts, dev, have.as_ref()) && newer(ts, dev, deleted.as_ref()) {
                item.id = id.clone();
                report.media_in += self.take_media_in(base, &mut item.media);
                if let Some(q) = item.quote.as_mut() {
                    report.media_in += self.take_media_in(base, &mut q.media);
                }
                let mut store = self.lock_store()?;
                store.upsert_all(std::slice::from_mut(&mut item))?;
                store.apply_remote_extras(&item)?;
                store.stamp(&id, "content", ts, dev)?;
                changed = true;
            }
        }
        // The rest only makes sense for an item we have.
        if self.lock_store()?.existing_ids(std::slice::from_ref(&id))?.is_empty() {
            return Ok(changed);
        }
        let mut store = self.lock_store()?;
        let take = |store: &mut Store, field: &str| -> Result<bool> {
            if newer(ts, dev, store.field_stamp(&id, field)?.as_ref()) {
                store.stamp(&id, field, ts, dev)?;
                Ok(true)
            } else {
                Ok(false)
            }
        };
        if let Some(tags) = &op.tags
            && take(&mut store, "tags")?
        {
            store.set_tags(&id, tags)?;
            changed = true;
        }
        if let Some(folder) = &op.folder
            && take(&mut store, "folder")?
        {
            let fid = if folder.is_empty() { None } else { Some(store.ensure_folder(folder)?) };
            store.move_to_folder(&id, fid)?;
            changed = true;
        }
        if let Some(note) = &op.note
            && take(&mut store, "note")?
        {
            store.set_note(&id, Some(note))?;
            changed = true;
        }
        if let Some(reviewed) = op.reviewed
            && take(&mut store, "reviewed")?
        {
            store.set_reviewed(std::slice::from_ref(&id), reviewed)?;
            changed = true;
        }
        if let Some(ai) = &op.ai
            && take(&mut store, "ai")?
        {
            store.set_ai(&id, ai.summary.as_deref(), &ai.tags)?;
            changed = true;
        }
        Ok(changed)
    }

    pub fn sync_status(&self) -> Result<Value> {
        let base = self.sync_base()?;
        let dev = self.device_id()?;
        let store = self.lock_store()?;
        let mut devices = vec![];
        if let Some(b) = &base
            && let Ok(entries) = fs::read_dir(b.join("devices"))
        {
            for e in entries.flatten() {
                if let Some(v) = fs::read(e.path()).ok().and_then(|b| serde_json::from_slice::<Value>(&b).ok()) {
                    devices.push(v);
                }
            }
        }
        Ok(json!({
            "enabled": store.sync_enabled()?,
            "dir": base.map(|b| b.display().to_string()),
            "device": dev,
            "name": store.setting("device_name")?,
            "media": store.setting("sync_media")?.unwrap_or_else(|| "images".into()),
            "pending": store.dirty_count()?,
            "devices": devices,
        }))
    }
}

pub(super) fn dispatch<S: Sink>(lib: &Arc<Library>, cmd: &str, req: Req<'_>) -> Option<Result<S::Out>> {
    #[derive(Deserialize)]
    struct Enable {
        dir: String,
        name: Option<String>,
        media: Option<String>,
    }
    Some(match cmd {
        "sync_enable" => req.parse::<Enable>().and_then(|a| S::ok(lib.sync_enable(Path::new(&a.dir), a.name.as_deref(), a.media.as_deref())?)),
        "sync_disable" => lib.sync_disable().and_then(|()| S::ok(true)),
        "sync_now" => lib.sync_now().and_then(S::ok),
        "sync_status" => lib.sync_status().and_then(S::ok),
        "sync_set_media" => {
            #[derive(Deserialize)]
            struct M {
                media: String,
            }
            req.parse::<M>().and_then(|m| {
                lib.lock_store()?.set_setting("sync_media", &m.media)?;
                S::ok(true)
            })
        }
        _ => return None,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn call(lib: &Arc<Library>, req: Value) -> Value {
        let r = handle_value(lib, req);
        assert_eq!(r.get("ok"), Some(&json!(true)), "{r}");
        r.get("data").cloned().unwrap_or(Value::Null)
    }

    #[test]
    fn two_devices_converge() {
        let root = std::env::temp_dir().join(format!("wm-sync-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        let shared = root.join("shared");
        let a = Library::open(&root.join("a")).unwrap_or_else(|_| std::process::abort());
        let b = Library::open(&root.join("b")).unwrap_or_else(|_| std::process::abort());

        // A has two posts, one with a picture on disk, a tag, a folder and a note.
        let pic = a.media.put(b"not really a jpeg", "jpg").unwrap_or_default();
        call(
            &a,
            json!({"cmd": "import_items", "tags": ["dev"], "items": [
            {"platform": "web", "url": "https://example.com/1", "text": "birinci", "media": [{"kind": "image", "url": "https://e.com/p.jpg", "file": pic}]},
            {"platform": "web", "url": "https://example.com/2", "text": "ikinci"}]}),
        );
        let ids: Vec<String> = call(&a, json!({"cmd": "search", "q": "", "sort": "saved_asc"}))
            .get("items")
            .and_then(Value::as_array)
            .map(|v| v.iter().filter_map(|i| i.get("id").and_then(Value::as_str).map(str::to_string)).collect())
            .unwrap_or_default();
        let (one, two) = (ids.first().cloned().unwrap_or_default(), ids.get(1).cloned().unwrap_or_default());
        let folder = call(&a, json!({"cmd": "add_folder", "name": "Ders/Rust"}));
        call(&a, json!({"cmd": "move_to_folder", "id": one, "folder_id": folder.get("id")}));
        call(&a, json!({"cmd": "set_note", "id": one, "note": "A'nın notu"}));
        call(&a, json!({"cmd": "ui_set", "key": "ui.saved_searches", "value": "[1]"}));

        let r = call(&a, json!({"cmd": "sync_enable", "dir": shared, "name": "Mac"}));
        assert_eq!(r.get("pushed"), Some(&json!(3)), "{r}");
        assert_eq!(r.get("media_out"), Some(&json!(1)));

        // B starts empty and gets everything, picture included, with no echo.
        let r = call(&b, json!({"cmd": "sync_enable", "dir": shared, "name": "iPhone"}));
        assert_eq!(r.get("applied"), Some(&json!(3)), "{r}");
        assert_eq!(r.get("media_in"), Some(&json!(1)));
        let got = call(&b, json!({"cmd": "get", "id": one}));
        assert_eq!(got.get("note"), Some(&json!("A'nın notu")));
        assert_eq!(got.pointer("/tags/0"), Some(&json!("dev")));
        assert_eq!(got.pointer("/media/0/file"), Some(&json!(pic)));
        assert!(b.media.contains(&pic));
        let folders = call(&b, json!({"cmd": "folders"}));
        assert!(folders.as_array().is_some_and(|f| f.iter().any(|x| x.get("name") == Some(&json!("Ders/Rust")))));
        assert_eq!(call(&b, json!({"cmd": "ui_get", "key": "ui.saved_searches"})), json!("[1]"));
        assert_eq!(call(&b, json!({"cmd": "sync_status"})).get("pending"), Some(&json!(0)));
        assert_eq!(call(&b, json!({"cmd": "sync_now"})).get("pushed"), Some(&json!(0)));

        // B retags one and deletes two; A tags two meanwhile (older than B's delete).
        call(&a, json!({"cmd": "edit_tags", "ids": [two], "add": ["a-tarafi"]}));
        call(&a, json!({"cmd": "sync_now"}));
        std::thread::sleep(Duration::from_millis(5));
        call(&b, json!({"cmd": "set_tags", "id": one, "tags": ["rust", "okunacak"]}));
        call(&b, json!({"cmd": "delete", "id": two}));
        call(&b, json!({"cmd": "sync_now"}));
        call(&a, json!({"cmd": "sync_now"}));
        let tags = call(&a, json!({"cmd": "get", "id": one}));
        assert_eq!(tags.get("tags"), Some(&json!(["okunacak", "rust"])), "{tags}");
        assert!(call(&a, json!({"cmd": "get", "id": two})).is_null());
        // The note A kept is untouched by B's tag change.
        assert_eq!(tags.get("note"), Some(&json!("A'nın notu")));

        // Both edit the note: the later write wins on both sides.
        call(&a, json!({"cmd": "set_note", "id": one, "note": "önce A"}));
        std::thread::sleep(Duration::from_millis(5));
        call(&b, json!({"cmd": "set_note", "id": one, "note": "sonra B"}));
        call(&a, json!({"cmd": "sync_now"}));
        call(&b, json!({"cmd": "sync_now"}));
        call(&a, json!({"cmd": "sync_now"}));
        for lib in [&a, &b] {
            assert_eq!(call(lib, json!({"cmd": "get", "id": one})).get("note"), Some(&json!("sonra B")));
        }
        a.shutdown();
        b.shutdown();
        let _ = fs::remove_dir_all(&root);
    }
}
