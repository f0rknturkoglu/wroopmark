//! The library handle and its JSON command surface, shared by the FFI layer
//! (Swift apps), the CLI and the Chromium native-messaging host.
//!
//! Request:  `{"cmd": "search", "q": "tag:dev rust"}`
//! Response: `{"ok": true, "data": ...}` or `{"ok": false, "error": "..."}`

use std::borrow::Cow;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, MutexGuard};
use std::thread::JoinHandle;
use std::time::Duration;

use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::db::{Saved, Store, StoreError};
use crate::external::ExternalError;
use crate::fetch::{FetchError, Fetcher};
use crate::media::MediaStore;
use crate::model::{Item, Media, MediaKind};
use crate::query::{Query, Sort};
use crate::text::{hash_hex, item_id_for_url, now};

pub const VERSION: &str = env!("CARGO_PKG_VERSION");

pub type Result<T> = std::result::Result<T, CoreError>;

#[derive(Debug, thiserror::Error)]
pub enum CoreError {
    #[error("{path}: {source}")]
    IoPath {
        path: String,
        #[source]
        source: std::io::Error,
    },
    #[error("{0}")]
    Io(#[from] std::io::Error),
    #[error("{0}")]
    Store(#[from] StoreError),
    #[error("{0}")]
    Fetch(#[from] FetchError),
    #[error("video indirilemedi: {0}")]
    External(#[from] ExternalError),
    #[error("{0}")]
    Json(#[from] serde_json::Error),
    #[error("geçersiz parça: {0}")]
    Base64(#[from] base64::DecodeError),
    #[error("kütüphane kilidi bozuldu")]
    LockPoisoned,
    #[error("cmd eksik")]
    MissingCmd,
    #[error("geçersiz JSON: {0}")]
    InvalidJson(serde_json::Error),
    #[error("geçersiz istek: {0}")]
    InvalidRequest(serde_json::Error),
    #[error("payload JSON değil: {0}")]
    InvalidPayloadJson(serde_json::Error),
    #[error("bilinmeyen komut: {0}")]
    UnknownCmd(String),
    #[error("kayıt yok")]
    ItemNotFound,
    #[error("kaydedilemedi")]
    SaveFailed,
    #[error("geçersiz URL")]
    InvalidUrl,
    #[error("geçersiz anahtar")]
    InvalidKey,
    #[error("value eksik")]
    MissingValue,
    #[error("geçersiz dosya adı: {0}")]
    InvalidFileName(String),
    #[error("yedek klasörü kütüphanenin içinde olamaz")]
    BackupInsideLibrary,
    #[error("bu kaydın beklenen bir videosu yok")]
    VideoNotExpected,
    #[error("video çok büyük")]
    VideoTooLarge,
    #[error("parça sırası bozuk: {have} bayt var, {expected} bekleniyordu")]
    ChunkOrder { have: u64, expected: u64 },
    #[error("video eksik geldi: {got} / {expected} bayt")]
    ChunkSize { got: u64, expected: u64 },
    #[error("sayı sınırı aşıldı")]
    NumericOverflow,
}

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
    stopping: AtomicBool,
    pub download_tracker: Arc<Mutex<Option<ActiveDownloadInfo>>>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ActiveDownloadInfo {
    pub id: String,
    pub platform: String,
    pub url: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub author_handle: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub author_name: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    pub text: String,
    pub progress: f32,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub speed: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub eta: Option<String>,
    pub status: String,
    pub started_at: i64,
}

#[derive(Debug, Default, serde::Serialize)]
pub struct BackupReport {
    pub path: String,
    pub db_bytes: u64,
    pub items: usize,
    pub files_total: usize,
    pub files_copied: usize,
    pub bytes_copied: u64,
}

#[derive(Debug, Default, serde::Serialize)]
pub struct ImportReport {
    pub new: usize,
    pub updated: usize,
    pub ids: Vec<String>,
}

#[derive(Debug, Serialize)]
pub struct LookupHit {
    pub id: String,
    pub title: Option<String>,
    pub tags: Vec<String>,
    pub folder_id: Option<i64>,
    pub folder: Option<String>,
    pub saved_at: i64,
}

struct TrackerGuard<'a>(&'a Mutex<Option<ActiveDownloadInfo>>);

impl Drop for TrackerGuard<'_> {
    fn drop(&mut self) {
        if let Ok(mut dt) = self.0.lock() {
            *dt = None;
        }
    }
}

struct WorkDirGuard<'a>(&'a Path);

impl Drop for WorkDirGuard<'_> {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(self.0);
    }
}

struct TempFileGuard<'a>(&'a Path);

impl Drop for TempFileGuard<'_> {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(self.0);
    }
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

    pub fn open(root: &Path) -> Result<Arc<Self>> {
        std::fs::create_dir_all(root).map_err(|source| CoreError::IoPath { path: root.display().to_string(), source })?;
        let store = Store::open(&root.join("library.sqlite"))?;
        Ok(Arc::new(Self {
            root: root.to_path_buf(),
            store: Mutex::new(store),
            media: MediaStore::new(root.join("media")),
            fetcher: Fetcher::new(),
            worker: Mutex::new(None),
            stopping: AtomicBool::new(false),
            download_tracker: Arc::new(Mutex::new(None)),
        }))
    }

    pub fn root(&self) -> &Path {
        &self.root
    }

    fn lock_store(&self) -> Result<MutexGuard<'_, Store>> {
        self.store.lock().map_err(|_| CoreError::LockPoisoned)
    }

    pub fn checkpoint(&self) {
        if let Ok(store) = self.store.lock() {
            store.checkpoint();
        }
    }

    /// Signals background media work to stop, waits for it to join, and checkpoints SQLite.
    pub fn shutdown(&self) {
        self.stopping.store(true, Ordering::Release);
        self.wait_media();
        self.checkpoint();
    }

    /// Saves a batch in one transaction: all of it or nothing.
    fn save_all(&self, mut items: Vec<Item>, tags: &[String]) -> Result<ImportReport> {
        self.save_into(&mut items, tags, None)
    }

    /// Like `save_all`, filing every item in `folder` when one is given.
    fn save_into(&self, items: &mut [Item], tags: &[String], folder: Option<i64>) -> Result<ImportReport> {
        for item in items.iter_mut() {
            if item.id.is_empty() {
                let (platform, id) = item_id_for_url(&item.url);
                item.platform = platform;
                item.id = id;
            }
            item.tags.extend(tags.iter().cloned());
            if folder.is_some() {
                item.folder_id = folder;
            }
        }
        let mut report = ImportReport::default();
        for Saved { id, created } in self.lock_store()?.upsert_all(items)? {
            if created {
                report.new += 1;
            } else {
                report.updated += 1;
            }
            report.ids.push(id);
        }
        Ok(report)
    }

    /// Captures a URL from the network and saves it with its media.
    pub fn add_url(&self, url: &str, tags: &[String], note: Option<&str>, folder: Option<i64>) -> Result<Item> {
        let mut item = self.fetcher.capture(url)?;
        item.note = note.map(str::to_string);
        self.fetcher.fill_media(&self.media, &mut item.media, self.videos_enabled());
        let report = self.save_into(std::slice::from_mut(&mut item), tags, folder)?;
        let id = report.ids.first().ok_or(CoreError::SaveFailed)?;
        let mut store = self.lock_store()?;
        store.set_media(id, &item.media, None)?;
        store.get(id)?.ok_or(CoreError::SaveFailed)
    }

    /// Saves every tweet in an x.com GraphQL response.
    pub fn import_x(&self, payload: &Value, tags: &[String]) -> Result<ImportReport> {
        // Timelines list newest first; saving oldest first keeps that order
        // among items that end up with the same save time.
        let mut items = crate::x::parse_timeline(payload);
        items.reverse();
        let mut report = self.save_all(items, tags)?;
        report.ids.reverse();
        Ok(report)
    }

    /// Saves every TikTok item in a TikTok web API response (favorites, …).
    pub fn import_tiktok(&self, payload: &Value, tags: &[String]) -> Result<ImportReport> {
        self.save_all(crate::tiktok::parse_api(payload), tags)
    }

    /// Saves items already shaped by a capturer (extensions, share sheet).
    pub fn import_items(&self, items: Vec<Item>, tags: &[String], folder: Option<i64>) -> Result<ImportReport> {
        let mut items = items;
        self.save_into(&mut items, tags, folder)
    }

    /// Saves every post in a Reddit listing (saved posts and comments).
    pub fn import_reddit(&self, payload: &Value, tags: &[String]) -> Result<ImportReport> {
        self.save_all(crate::reddit::parse_listing(payload), tags)
    }

    /// Saves every post in an Instagram web API response (the Saved page).
    pub fn import_instagram(&self, payload: &Value, tags: &[String]) -> Result<ImportReport> {
        self.save_all(crate::instagram::parse_api(payload), tags)
    }

    /// Checks up to `limit` links not checked for a week; returns how many.
    pub fn check_links(&self, limit: i64) -> Result<usize> {
        const WEEK: i64 = 7 * 24 * 3600;
        let todo = self.lock_store()?.links_to_check(limit, WEEK)?;
        for (id, url) in &todo {
            let (status, dead) = self.fetcher.check(url);
            self.lock_store()?.set_link_status(*id, status, dead)?;
        }
        Ok(todo.len())
    }

    /// The saved item for a page the browser is on, if any.
    pub fn lookup_url(&self, url: &str) -> Result<Option<LookupHit>> {
        let (_, id) = item_id_for_url(url);
        let norm = crate::text::normalize_url(url).unwrap_or_else(|| url.to_string());
        let store = self.lock_store()?;
        let Some(item) = store.lookup(&id, &norm)? else { return Ok(None) };
        let folder = match item.folder_id {
            Some(f) => store.folders()?.into_iter().find(|x| x.id == f).map(|x| x.name),
            None => None,
        };
        Ok(Some(LookupHit { id: item.id, title: item.title, tags: item.tags, folder_id: item.folder_id, folder, saved_at: item.saved_at }))
    }

    /// Mirrors the library into `dest`: a consistent copy of the database,
    /// the media files the copy lacks (names are content hashes, so a file
    /// already there is the same file), and `items.jsonl`, a plain export
    /// any other program can read. Nothing in `dest` is ever deleted.
    pub fn backup(&self, dest: &Path) -> Result<BackupReport> {
        let io_err = |source: std::io::Error| CoreError::IoPath { path: dest.display().to_string(), source };
        let root = self.root.canonicalize().unwrap_or_else(|_| self.root.clone());
        let existed = dest.exists();
        std::fs::create_dir_all(dest).map_err(io_err)?;
        let dest_abs = dest.canonicalize().map_err(io_err)?;
        if dest_abs.starts_with(&root) {
            if !existed {
                let _ = std::fs::remove_dir(dest);
            }
            return Err(CoreError::BackupInsideLibrary);
        }
        let mut report = BackupReport { path: dest_abs.display().to_string(), ..Default::default() };

        let tmp = dest.join("library.sqlite.tmp");
        let _ = std::fs::remove_file(&tmp);
        {
            let _db_guard = TempFileGuard(&tmp);
            self.lock_store()?.backup_to(&tmp)?;
            std::fs::rename(&tmp, dest.join("library.sqlite")).map_err(io_err)?;
        }
        report.db_bytes = std::fs::metadata(dest.join("library.sqlite")).map(|m| m.len()).unwrap_or(0);

        let src_media = self.media.root();
        if let Ok(shards) = std::fs::read_dir(src_media) {
            for shard in shards.flatten() {
                if !shard.file_type().is_ok_and(|t| t.is_dir()) {
                    continue;
                }
                let out_dir = dest.join("media").join(shard.file_name());
                for f in std::fs::read_dir(shard.path()).map_err(io_err)?.flatten() {
                    if !f.file_type().is_ok_and(|t| t.is_file()) {
                        continue;
                    }
                    let name_os = f.file_name();
                    let Some(name) = name_os.to_str() else {
                        continue;
                    };
                    if !crate::media::is_name(name) {
                        continue;
                    }
                    report.files_total += 1;
                    let len = f.metadata().map(|m| m.len()).unwrap_or(0);
                    let target = out_dir.join(name);
                    if std::fs::metadata(&target).is_ok_and(|m| m.len() == len) {
                        continue;
                    }
                    std::fs::create_dir_all(&out_dir).map_err(io_err)?;
                    let part = out_dir.join(format!(".{name}.part"));
                    let _part_guard = TempFileGuard(&part);
                    std::fs::copy(f.path(), &part).map_err(io_err)?;
                    std::fs::rename(&part, &target).map_err(io_err)?;
                    report.files_copied += 1;
                    report.bytes_copied += len;
                }
            }
        }

        report.items = self.export_jsonl(&dest.join("items.jsonl")).map_err(io_err)?;
        let readme = "wroopmark yedeği\n\n\
            library.sqlite + media/ birlikte tam kütüphanedir. Geri yüklemek için uygulamayı kapat,\n\
            ikisini ~/Library/Application Support/wroopmark/ içine kopyala (eskisinin yerine), sonra aç.\n\n\
            items.jsonl: her satır bir kayıt (metin, yazar, etiketler, klasör, not, medya dosya adları);\n\
            başka programlarla okumak için.\n";
        std::fs::write(dest.join("OKUBENI.txt"), readme).map_err(io_err)?;
        Ok(report)
    }

    fn export_jsonl(&self, path: &Path) -> std::io::Result<usize> {
        use std::io::Write;
        #[derive(Serialize)]
        struct ExportRow<'a> {
            #[serde(flatten)]
            item: &'a Item,
            #[serde(skip_serializing_if = "Option::is_none")]
            folder: Option<&'a str>,
        }
        let tmp = path.with_extension("jsonl.tmp");
        let _tmp_guard = TempFileGuard(&tmp);
        let mut out = std::io::BufWriter::new(std::fs::File::create(&tmp)?);
        let folders: std::collections::HashMap<i64, String> =
            self.lock_store().ok().and_then(|s| s.folders().ok()).unwrap_or_default().into_iter().map(|f| (f.id, f.name)).collect();
        let q = Query::parse("");
        let sort = Sort::parse("saved_asc");
        let mut offset: i64 = 0;
        let mut n = 0;
        loop {
            let page = self.lock_store().map_err(std::io::Error::other)?.search(&q, sort, 500, offset).map_err(std::io::Error::other)?;
            if page.items.is_empty() {
                break;
            }
            let page_len = i64::try_from(page.items.len()).map_err(std::io::Error::other)?;
            offset = offset.checked_add(page_len).ok_or_else(|| std::io::Error::other("offset overflow"))?;
            for mut item in page.items {
                item.raw = None;
                let folder = item.folder_id.and_then(|f| folders.get(&f)).map(String::as_str);
                serde_json::to_writer(&mut out, &ExportRow { item: &item, folder }).map_err(std::io::Error::other)?;
                out.write_all(b"\n")?;
                n += 1;
            }
        }
        out.flush()?;
        drop(out);
        std::fs::rename(&tmp, path)?;
        Ok(n)
    }

    /// Videos are downloaded unless turned off in the settings.
    pub fn videos_enabled(&self) -> bool {
        self.lock_store().ok().and_then(|s| s.setting("download_videos").ok().flatten()).is_none_or(|v| v != "0")
    }

    pub fn set_videos_enabled(self: &Arc<Self>, on: bool) -> Result<()> {
        let mut store = self.lock_store()?;
        store.set_setting("download_videos", if on { "1" } else { "0" })?;
        if on {
            store.queue_videos()?;
            drop(store);
            self.kick_media();
        }
        Ok(())
    }

    /// Points media at files already on disk for the same URL (the same
    /// picture in another post), so only new things hit the network.
    fn reuse_known_files(&self, media: &mut [Media]) {
        let Ok(store) = self.lock_store() else { return };
        for m in media.iter_mut() {
            if m.file.is_none() {
                let src = m.local_source();
                m.file = store.known_file(src).ok().flatten().filter(|f| self.media.contains(f));
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
    pub fn fetch_pending_media(&self, limit: i64) -> Result<usize> {
        let pending = self.lock_store()?.pending_media(limit)?;
        let videos = self.videos_enabled();
        let mut done = 0;
        for mut item in pending {
            if self.stopping.load(Ordering::Acquire) {
                break;
            }
            self.fill_item(&mut item, videos);
            self.lock_store()?.set_media(&item.id, &item.media, item.quote.as_deref())?;
            done += 1;
        }
        Ok(done)
    }

    /// Which of these items still lack their video file.
    pub fn videos_needed(&self, ids: &[String]) -> Result<Vec<String>> {
        if !self.videos_enabled() {
            return Ok(vec![]);
        }
        let store = self.lock_store()?;
        let mut out = vec![];
        for id in ids {
            if let Some(item) = store.get(id)?.filter(Self::needs_video) {
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
    pub fn upload_chunk(&self, c: &Chunk) -> Result<Option<Item>> {
        use base64::Engine;
        use std::io::Write;
        const MAX: u64 = 600 << 20;
        let dir = self.root.join(".uploads");
        std::fs::create_dir_all(&dir)?;
        let part = dir.join(format!("{}.part", hash_hex(c.id.as_bytes())));
        let fail = |e: CoreError| -> Result<Option<Item>> {
            let _ = std::fs::remove_file(&part);
            Err(e)
        };
        if c.seq == 0 && !self.lock_store()?.get(&c.id)?.is_some_and(|i| Self::needs_video(&i)) {
            return Err(CoreError::VideoNotExpected);
        }
        let have = if c.seq == 0 { 0 } else { std::fs::metadata(&part).map(|m| m.len()).unwrap_or(0) };
        if c.offset.is_some_and(|o| o != have) || (c.seq > 0 && have == 0) {
            return fail(CoreError::ChunkOrder { have, expected: c.offset.unwrap_or(0) });
        }
        let bytes = match base64::engine::general_purpose::STANDARD.decode(&c.data) {
            Ok(b) => b,
            Err(e) => return fail(CoreError::Base64(e)),
        };
        let (seq, last) = (c.seq, c.last);
        let len = {
            let res = (|| -> std::io::Result<u64> {
                let mut f = std::fs::OpenOptions::new().create(seq == 0).write(true).append(seq > 0).truncate(seq == 0).open(&part)?;
                f.write_all(&bytes)?;
                Ok(f.metadata()?.len())
            })();
            match res {
                Ok(l) => l,
                Err(e) => return fail(CoreError::Io(e)),
            }
        };
        if len > MAX {
            return fail(CoreError::VideoTooLarge);
        }
        if !last {
            return Ok(None);
        }
        if c.size.is_some_and(|s| s != len) {
            return fail(CoreError::ChunkSize { got: len, expected: c.size.unwrap_or(0) });
        }
        // Checked again: another process may have saved it meanwhile.
        let item = match self.lock_store()?.get(&c.id) {
            Ok(it) => it.filter(Self::needs_video),
            Err(e) => return fail(CoreError::Store(e)),
        };
        let Some(mut item) = item else { return fail(CoreError::VideoNotExpected) };
        let name = {
            let _part_guard = TempFileGuard(&part);
            let reader = std::fs::File::open(&part)?;
            self.media.put_reader(reader, &c.content_type)?
        };
        if let Some(m) = item.media.iter_mut().find(|m| m.kind != MediaKind::Image && m.video_file.is_none()) {
            m.video_file = Some(name);
        }
        let mut store = self.lock_store()?;
        store.set_media(&c.id, &item.media, item.quote.as_deref())?;
        Ok(store.get(&c.id)?)
    }

    /// Downloads everything one item has, videos included, right now.
    /// Pictures and direct video files first, then videos that need an
    /// outside tool (whatever their earlier tries).
    pub fn download_item(&self, id: &str) -> Result<Item> {
        let mut item = self.lock_store()?.get(id)?.ok_or(CoreError::ItemNotFound)?;
        self.fill_item(&mut item, true);
        self.lock_store()?.set_media(id, &item.media, item.quote.as_deref())?;
        if needs_external_video(&item) {
            self.fetch_external_video(&mut item)?;
        }
        self.lock_store()?.get(id)?.ok_or(CoreError::ItemNotFound)
    }

    /// Fetches the item's post-page videos with yt-dlp / gallery-dl and
    /// stores them. On failure the item waits before it is tried again.
    fn fetch_external_video(&self, item: &mut Item) -> Result<()> {
        let work = self.root.join(".downloads").join(format!("{}-{}", std::process::id(), hash_hex(item.id.as_bytes())));
        let _work_guard = WorkDirGuard(&work);
        {
            let mut dt = self.download_tracker.lock().map_err(|_| CoreError::LockPoisoned)?;
            *dt = Some(ActiveDownloadInfo {
                id: item.id.clone(),
                platform: item.platform.as_str().to_string(),
                url: item.url.clone(),
                author_handle: item.author_handle.clone(),
                author_name: item.author_name.clone(),
                title: item.title.clone(),
                text: item.text.clone(),
                progress: 0.0,
                speed: None,
                eta: None,
                status: "downloading".into(),
                started_at: now(),
            });
        }
        let _tracker_guard = TrackerGuard(&self.download_tracker);
        let tracker = self.download_tracker.clone();
        let on_progress: Option<crate::external::ProgressCallback> = Some(Arc::new(move |pct, speed, eta| {
            if let Ok(mut dt) = tracker.lock()
                && let Some(active) = dt.as_mut()
            {
                active.progress = pct;
                active.speed = speed.map(str::to_string);
                active.eta = eta.map(str::to_string);
            }
        }));
        let mut result: Result<()> = Ok(());
        for m in item.media.iter_mut().filter(|m| m.kind != MediaKind::Image && m.video_file.is_none() && m.downloadable_video().is_none()) {
            let got = (|| -> Result<String> {
                let file = crate::external::download_with_progress(&m.url, &work, on_progress.as_ref(), &self.stopping)?;
                let f = std::fs::File::open(&file)?;
                Ok(self.media.put_reader(f, "")?)
            })();
            match got {
                Ok(name) => m.video_file = Some(name),
                Err(e) => result = Err(e),
            }
        }
        drop(_tracker_guard);
        let mut store = self.lock_store()?;
        store.set_media(&item.id, &item.media, item.quote.as_deref())?;
        if result.is_err() {
            store.video_failed(&item.id)?;
        }
        result
    }

    /// Works through up to `limit` queued outside-tool videos. Returns how
    /// many items were tried; errors are logged, not returned.
    pub fn download_external_videos(&self, limit: i64) -> Result<usize> {
        if self.stopping.load(Ordering::Acquire) || !self.videos_enabled() || crate::external::available().is_empty() {
            return Ok(0);
        }
        let queue = self.lock_store()?.external_video_queue(limit)?;
        let count = queue.len();
        for (i, mut item) in queue.into_iter().enumerate() {
            if i > 0 {
                // One at a time, unhurried: this is a personal archive, not a crawler.
                for _ in 0..10 {
                    if self.stopping.load(Ordering::Acquire) {
                        return Ok(i);
                    }
                    std::thread::sleep(Duration::from_millis(200));
                }
            }
            if self.stopping.load(Ordering::Acquire) {
                return Ok(i);
            }
            if let Err(e) = self.fetch_external_video(&mut item) {
                append_log(&self.root, &format!("video {}: {e}", item.id));
            }
        }
        Ok(count)
    }

    /// Starts a background media download pass unless one is running.
    pub fn kick_media(self: &Arc<Self>) {
        if self.stopping.load(Ordering::Acquire) {
            return;
        }
        let Ok(mut slot) = self.worker.lock() else { return };
        if slot.as_ref().is_some_and(|h| !h.is_finished()) {
            return;
        }
        let lib = Arc::clone(self);
        *slot = Some(std::thread::spawn(move || {
            loop {
                if lib.stopping.load(Ordering::Acquire) {
                    break;
                }
                match lib.fetch_pending_media(10) {
                    Ok(n) if n > 0 => {}
                    _ => break,
                }
            }
        }));
    }

    /// Blocks until the background media pass (if any) is done.
    pub fn wait_media(&self) {
        let Ok(mut slot) = self.worker.lock() else { return };
        if let Some(h) = slot.take() {
            let _ = h.join();
        }
    }

    /// Fetches titles/descriptions for links that have none yet. A page that
    /// cannot be fetched is not marked done; it is tried again later.
    pub fn enrich_links(&self, limit: i64) -> Result<usize> {
        let todo = self.lock_store()?.links_to_enrich(limit)?;
        let n = todo.len();
        for (id, url) in todo {
            if self.stopping.load(Ordering::Acquire) {
                break;
            }
            match self.fetcher.page(&url) {
                Ok(meta) => self.lock_store()?.set_link_meta(id, meta.title.as_deref(), meta.description.as_deref(), meta.image.as_deref())?,
                Err(_) => self.lock_store()?.link_fetch_failed(id)?,
            }
        }
        Ok(n)
    }

    pub fn delete(&self, id: &str) -> Result<usize> {
        let orphans = self.lock_store()?.delete(id)?;
        for f in &orphans {
            self.media.remove(f);
        }
        Ok(orphans.len())
    }
}

fn needs_external_video(item: &Item) -> bool {
    item.media.iter().any(|m| m.kind != MediaKind::Image && m.video_file.is_none() && m.downloadable_video().is_none())
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
struct LinkItemsPage {
    id: i64,
    #[serde(default = "default_link_items_limit")]
    limit: i64,
    #[serde(default)]
    offset: i64,
}

fn default_link_items_limit() -> i64 {
    60
}

#[derive(Deserialize)]
struct Page {
    #[serde(default)]
    q: String,
    #[serde(default = "default_limit")]
    limit: i64,
    #[serde(default)]
    offset: i64,
    /// See [`Sort::parse`].
    #[serde(default)]
    sort: String,
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
    folder_id: Option<i64>,
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
    folder_id: Option<i64>,
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
struct AddFolder {
    name: String,
}

#[derive(Deserialize)]
struct RenameFolder {
    id: i64,
    name: String,
}

#[derive(Deserialize)]
struct FolderId {
    id: i64,
}

#[derive(Deserialize)]
struct MoveToFolder {
    id: String,
    folder_id: Option<i64>,
}

#[derive(Deserialize)]
struct MoveItemsToFolder {
    ids: Vec<String>,
    folder_id: Option<i64>,
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

#[derive(Serialize)]
struct ApiOk<T: Serialize> {
    ok: bool,
    data: T,
}

#[derive(Serialize)]
struct ApiErr<'a> {
    ok: bool,
    error: &'a str,
}

trait Sink {
    type Out;
    fn ok<T: Serialize>(v: T) -> Result<Self::Out>;
}

struct StringSink;

impl Sink for StringSink {
    type Out = String;
    fn ok<T: Serialize>(v: T) -> Result<String> {
        Ok(serde_json::to_string(&ApiOk { ok: true, data: v })?)
    }
}

struct ValueSink;

impl Sink for ValueSink {
    type Out = Value;
    fn ok<T: Serialize>(v: T) -> Result<Value> {
        Ok(serde_json::json!({ "ok": true, "data": serde_json::to_value(v)? }))
    }
}

enum Req<'a> {
    Json(&'a str),
    Val(Value),
}

impl Req<'_> {
    fn parse<T: DeserializeOwned>(self) -> Result<T> {
        match self {
            Self::Json(raw) => serde_json::from_str(raw).map_err(CoreError::InvalidRequest),
            Self::Val(val) => serde_json::from_value(val).map_err(CoreError::InvalidRequest),
        }
    }
}

#[derive(Deserialize)]
struct CmdPeek<'a> {
    #[serde(borrow)]
    cmd: Option<Cow<'a, str>>,
}

fn err_json(msg: &str) -> String {
    serde_json::to_string(&ApiErr { ok: false, error: msg }).unwrap_or_else(|_| r#"{"ok":false,"error":"hata"}"#.into())
}

fn err_val(msg: &str) -> Value {
    serde_json::json!({ "ok": false, "error": msg })
}

pub fn handle_json(lib: &Arc<Library>, raw: &str) -> String {
    let peek: CmdPeek<'_> = match serde_json::from_str(raw) {
        Ok(p) => p,
        Err(e) if e.is_syntax() || e.is_eof() => return err_json(&CoreError::InvalidJson(e).to_string()),
        Err(_) => return err_json(&CoreError::MissingCmd.to_string()),
    };
    let Some(cmd) = peek.cmd.as_deref() else {
        return err_json(&CoreError::MissingCmd.to_string());
    };
    match dispatch_with::<StringSink>(lib, cmd, Req::Json(raw)) {
        Ok(s) => s,
        Err(e) => err_json(&e.to_string()),
    }
}

pub fn handle(lib: &Arc<Library>, raw: &str) -> Value {
    let peek: CmdPeek<'_> = match serde_json::from_str(raw) {
        Ok(p) => p,
        Err(e) if e.is_syntax() || e.is_eof() => return err_val(&CoreError::InvalidJson(e).to_string()),
        Err(_) => return err_val(&CoreError::MissingCmd.to_string()),
    };
    let Some(cmd) = peek.cmd.as_deref() else {
        return err_val(&CoreError::MissingCmd.to_string());
    };
    match dispatch_with::<ValueSink>(lib, cmd, Req::Json(raw)) {
        Ok(v) => v,
        Err(e) => err_val(&e.to_string()),
    }
}

pub fn handle_value(lib: &Arc<Library>, req: Value) -> Value {
    let Some(cmd) = req.get("cmd").and_then(Value::as_str).map(str::to_string) else {
        return err_val(&CoreError::MissingCmd.to_string());
    };
    match dispatch_with::<ValueSink>(lib, &cmd, Req::Val(req)) {
        Ok(v) => v,
        Err(e) => err_val(&e.to_string()),
    }
}

fn dispatch_with<S: Sink>(lib: &Arc<Library>, cmd: &str, req: Req<'_>) -> Result<S::Out> {
    match cmd {
        "ping" => {
            #[derive(Serialize)]
            struct Ping<'a> {
                version: &'static str,
                library: &'a Path,
            }
            S::ok(Ping { version: VERSION, library: lib.root() })
        }
        "log" => {
            #[derive(Deserialize)]
            struct LogReq {
                #[serde(default)]
                line: Option<Value>,
            }
            let r: LogReq = req.parse()?;
            let raw_line = r.line.as_ref().and_then(Value::as_str).unwrap_or("");
            // One line per entry: control characters cannot forge others.
            let line: String = raw_line.chars().take(500).map(|c| if c.is_control() { ' ' } else { c }).collect();
            append_log(lib.root(), &format!("eklenti: {line}"));
            S::ok(true)
        }
        "stats" => {
            #[derive(Serialize)]
            struct StatsResp {
                #[serde(flatten)]
                stats: crate::db::Stats,
                media_bytes: u64,
            }
            let stats = lib.lock_store()?.stats()?;
            S::ok(StatsResp { stats, media_bytes: lib.media.bytes() })
        }
        "settings" => {
            #[derive(Serialize)]
            struct SettingsResp {
                download_videos: bool,
            }
            S::ok(SettingsResp { download_videos: lib.videos_enabled() })
        }
        "set_settings" => {
            #[derive(Deserialize)]
            struct SetSettingsReq {
                #[serde(default)]
                download_videos: Option<Value>,
            }
            #[derive(Serialize)]
            struct SettingsResp {
                download_videos: bool,
            }
            let r: SetSettingsReq = req.parse()?;
            if let Some(on) = r.download_videos.as_ref().and_then(Value::as_bool) {
                lib.set_videos_enabled(on)?;
            }
            S::ok(SettingsResp { download_videos: lib.videos_enabled() })
        }
        "videos_needed" => {
            #[derive(Deserialize)]
            struct Ids {
                ids: Vec<String>,
            }
            S::ok(lib.videos_needed(&req.parse::<Ids>()?.ids)?)
        }
        "upload_chunk" => S::ok(lib.upload_chunk(&req.parse::<Chunk>()?)?),
        "download_media" => S::ok(lib.download_item(&req.parse::<Id>()?.id)?),
        // Run by the app (the browser extensions' processes may not start
        // other programs).
        "download_videos" => S::ok(lib.download_external_videos(req.parse::<Limit>()?.limit)?),
        "video_tools" => {
            #[derive(Serialize)]
            struct ToolInfo {
                name: &'static str,
                path: PathBuf,
            }
            let tools: Vec<ToolInfo> = crate::external::available().into_iter().map(|(t, path)| ToolInfo { name: t.name(), path }).collect();
            S::ok(tools)
        }
        "data_version" => S::ok(lib.lock_store()?.data_version()?),
        // Folds the WAL into the main file; the app sends it when quitting.
        "checkpoint" => {
            lib.checkpoint();
            S::ok(true)
        }

        "add_url" => {
            let a: AddUrl = req.parse()?;
            S::ok(lib.add_url(&a.url, &a.tags, a.note.as_deref(), a.folder_id)?)
        }
        "import_x" | "import_tiktok" | "import_reddit" | "import_instagram" => {
            let a: ImportPayload = req.parse()?;
            let mut items = {
                let payload = match a.payload {
                    Value::String(s) => serde_json::from_str(&s).map_err(CoreError::InvalidPayloadJson)?,
                    v => v,
                };
                match cmd {
                    "import_x" => {
                        let mut parsed = crate::x::parse_timeline(&payload);
                        parsed.reverse();
                        parsed
                    }
                    "import_reddit" => crate::reddit::parse_listing(&payload),
                    "import_instagram" => crate::instagram::parse_api(&payload),
                    _ => crate::tiktok::parse_api(&payload),
                }
            };
            let mut report = lib.save_into(&mut items, &a.tags, None)?;
            if cmd == "import_x" {
                report.ids.reverse();
            }
            lib.kick_media();
            S::ok(report)
        }
        "import_items" => {
            let a: ImportItems = req.parse()?;
            let report = lib.import_items(a.items, &a.tags, a.folder_id)?;
            lib.kick_media();
            S::ok(report)
        }

        "search" => {
            let p: Page = req.parse()?;
            S::ok(lib.lock_store()?.search(&Query::parse(&p.q), Sort::parse(&p.sort), p.limit.clamp(1, 500), p.offset.max(0))?)
        }
        "set_reviewed" => {
            #[derive(Deserialize)]
            struct Reviewed {
                ids: Vec<String>,
                reviewed: bool,
            }
            let a: Reviewed = req.parse()?;
            S::ok(lib.lock_store()?.set_reviewed(&a.ids, a.reviewed)?)
        }
        "reset_reviewed" => S::ok(lib.lock_store()?.reset_reviewed()?),
        "get" => S::ok(lib.lock_store()?.get(&req.parse::<Id>()?.id)?),
        "raw" => S::ok(lib.lock_store()?.raw(&req.parse::<Id>()?.id)?),
        "delete" => S::ok(lib.delete(&req.parse::<Id>()?.id)?),

        "tags" => S::ok(lib.lock_store()?.tags()?),
        "set_tags" => {
            let a: SetTags = req.parse()?;
            lib.lock_store()?.set_tags(&a.id, &a.tags)?;
            S::ok(true)
        }
        "edit_tags" => {
            let a: EditTags = req.parse()?;
            lib.lock_store()?.edit_tags(&a.ids, &a.add, &a.remove)?;
            S::ok(true)
        }
        "rename_tag" => {
            let a: RenameTag = req.parse()?;
            S::ok(lib.lock_store()?.rename_tag(&a.from, &a.to)?)
        }

        "folders" => S::ok(lib.lock_store()?.folders()?),
        "add_folder" => {
            let a: AddFolder = req.parse()?;
            S::ok(lib.lock_store()?.add_folder(&a.name)?)
        }
        "rename_folder" => {
            let a: RenameFolder = req.parse()?;
            lib.lock_store()?.rename_folder(a.id, &a.name)?;
            S::ok(true)
        }
        "delete_folder" => {
            let a: FolderId = req.parse()?;
            lib.lock_store()?.delete_folder(a.id)?;
            S::ok(true)
        }
        "move_to_folder" => {
            let a: MoveToFolder = req.parse()?;
            lib.lock_store()?.move_to_folder(&a.id, a.folder_id)?;
            S::ok(true)
        }
        "move_items_to_folder" => {
            let a: MoveItemsToFolder = req.parse()?;
            lib.lock_store()?.move_items_to_folder(&a.ids, a.folder_id)?;
            S::ok(true)
        }

        "downloads" => {
            #[derive(Serialize)]
            struct QueuedRow {
                id: String,
                platform: &'static str,
                url: String,
                author_handle: Option<String>,
                author_name: Option<String>,
                title: Option<String>,
                text: String,
                status: &'static str,
                saved_at: i64,
            }
            #[derive(Serialize)]
            struct CompletedRow {
                id: String,
                platform: &'static str,
                url: String,
                author_handle: Option<String>,
                author_name: Option<String>,
                title: Option<String>,
                text: String,
                status: &'static str,
                video_file: Option<String>,
                file_size: Option<i64>,
                saved_at: i64,
            }
            #[derive(Serialize)]
            struct FailedRow {
                id: String,
                platform: &'static str,
                url: String,
                author_handle: Option<String>,
                author_name: Option<String>,
                title: Option<String>,
                text: String,
                status: &'static str,
                tries: i64,
                saved_at: i64,
            }
            #[derive(Serialize)]
            struct DownloadsResp<'a> {
                active: &'a [ActiveDownloadInfo],
                queued: Vec<QueuedRow>,
                completed: Vec<CompletedRow>,
                failed: Vec<FailedRow>,
            }
            let active = {
                let dt = lib.download_tracker.lock().map_err(|_| CoreError::LockPoisoned)?;
                dt.clone()
            };
            let (queued_items, completed_items, failed_items) = {
                let store = lib.lock_store()?;
                (store.external_video_queue(25)?, store.completed_video_downloads(30)?, store.failed_video_downloads(20)?)
            };
            let queued = queued_items
                .into_iter()
                .filter(|i| active.as_ref().is_none_or(|a| a.id != i.id))
                .map(|i| QueuedRow {
                    id: i.id,
                    platform: i.platform.as_str(),
                    url: i.url,
                    author_handle: i.author_handle,
                    author_name: i.author_name,
                    title: i.title,
                    text: i.text,
                    status: "queued",
                    saved_at: i.saved_at,
                })
                .collect();
            let completed = completed_items
                .into_iter()
                .map(|i| {
                    let file = i.media.into_iter().find_map(|m| m.video_file);
                    let size = file.as_deref().and_then(|f| lib.media.file_size(f));
                    CompletedRow {
                        id: i.id,
                        platform: i.platform.as_str(),
                        url: i.url,
                        author_handle: i.author_handle,
                        author_name: i.author_name,
                        title: i.title,
                        text: i.text,
                        status: "completed",
                        video_file: file,
                        file_size: size,
                        saved_at: i.saved_at,
                    }
                })
                .collect();
            let failed = failed_items
                .into_iter()
                .map(|i| FailedRow {
                    id: i.id,
                    platform: i.platform.as_str(),
                    url: i.url,
                    author_handle: i.author_handle,
                    author_name: i.author_name,
                    title: i.title,
                    text: i.text,
                    status: "failed",
                    tries: i.video_tries,
                    saved_at: i.saved_at,
                })
                .collect();
            S::ok(DownloadsResp { active: active.as_slice(), queued, completed, failed })
        }
        "retry_download" => {
            let id = req.parse::<Id>()?.id;
            let item = {
                let mut store = lib.lock_store()?;
                store.retry_video_download(&id)?;
                store.get(&id).ok().flatten()
            };
            if let Some(mut it) = item
                && it.media.iter().any(|m| m.kind != MediaKind::Image && m.video_file.is_none())
            {
                let _ = lib.fetch_external_video(&mut it);
            }
            lib.kick_media();
            S::ok(true)
        }
        "retry_all_downloads" => {
            let n = lib.lock_store()?.retry_all_video_downloads()?;
            lib.kick_media();
            S::ok(n)
        }
        "set_note" => {
            let a: SetNote = req.parse()?;
            lib.lock_store()?.set_note(&a.id, a.note.as_deref())?;
            S::ok(true)
        }
        "ocr_pending" => {
            #[derive(Serialize)]
            struct OcrRow {
                id: String,
                files: Vec<PathBuf>,
            }
            let limit = req.parse::<Limit>()?.limit;
            let rows = lib.lock_store()?.ocr_pending(limit)?;
            let paths: Vec<OcrRow> =
                rows.into_iter().map(|(id, files)| OcrRow { id, files: files.iter().map(|f| lib.media.path(f)).collect() }).collect();
            S::ok(paths)
        }
        "set_ocr" => {
            let a: SetExtra = req.parse()?;
            lib.lock_store()?.set_ocr(&a.id, &a.text)?;
            S::ok(true)
        }
        "set_extra" => {
            let a: SetExtra = req.parse()?;
            lib.lock_store()?.set_extra(&a.id, &a.text)?;
            S::ok(true)
        }

        "links" => {
            let p: Page = req.parse()?;
            S::ok(lib.lock_store()?.links(&p.q, p.limit.clamp(1, 500), p.offset.max(0))?)
        }
        "link_counts" => S::ok(lib.lock_store()?.link_counts()?),
        "links_page" => {
            #[derive(Deserialize)]
            struct LinksPageReq {
                #[serde(default)]
                q: String,
                #[serde(default)]
                category: Option<String>,
                #[serde(default)]
                only_dead: bool,
                #[serde(default = "default_links_page_limit")]
                limit: i64,
                #[serde(default)]
                offset: i64,
            }
            fn default_links_page_limit() -> i64 {
                100
            }
            let p: LinksPageReq = req.parse()?;
            let cat = p.category.as_deref().and_then(crate::db::LinkCategory::parse);
            S::ok(lib.lock_store()?.links_page(&p.q, cat, p.only_dead, p.limit.clamp(1, 200), p.offset.max(0))?)
        }
        "link_items" => {
            let p = req.parse::<LinkItemsPage>()?;
            S::ok(lib.lock_store()?.link_items(p.id, p.limit, p.offset)?)
        }
        "add_link" => S::ok(lib.lock_store()?.add_link(&req.parse::<Url>()?.url)?.ok_or(CoreError::InvalidUrl)?),
        "delete_link" => {
            lib.lock_store()?.delete_link(req.parse::<LinkId>()?.id)?;
            S::ok(true)
        }
        "enrich_links" => S::ok(lib.enrich_links(req.parse::<Limit>()?.limit)?),
        "check_links" => S::ok(lib.check_links(req.parse::<Limit>()?.limit)?),
        "lookup_url" => S::ok(lib.lookup_url(&req.parse::<Url>()?.url)?),
        "suggest_folders" => {
            #[derive(Deserialize)]
            struct Suggest {
                id: String,
                #[serde(default = "three")]
                limit: i64,
            }
            fn three() -> i64 {
                3
            }
            let a: Suggest = req.parse()?;
            S::ok(lib.lock_store()?.suggest_folders(&a.id, a.limit.clamp(1, 20))?)
        }
        "backup" => {
            #[derive(Deserialize)]
            struct Dest {
                dest: String,
            }
            S::ok(lib.backup(Path::new(&req.parse::<Dest>()?.dest))?)
        }
        // Small UI state kept in the library (and so in its backups):
        // saved searches and the like. Only `ui.` keys.
        "ui_get" => {
            #[derive(Deserialize)]
            struct UiGetReq {
                #[serde(default)]
                key: Option<Value>,
            }
            let r: UiGetReq = req.parse()?;
            let key = r.key.as_ref().and_then(Value::as_str).filter(|k| k.starts_with("ui.")).ok_or(CoreError::InvalidKey)?;
            S::ok(lib.lock_store()?.setting(key)?)
        }
        "ui_set" => {
            #[derive(Deserialize)]
            struct UiSetReq {
                #[serde(default)]
                key: Option<Value>,
                #[serde(default)]
                value: Option<Value>,
            }
            let r: UiSetReq = req.parse()?;
            let key = r.key.as_ref().and_then(Value::as_str).filter(|k| k.starts_with("ui.")).ok_or(CoreError::InvalidKey)?;
            let value = r.value.as_ref().and_then(Value::as_str).ok_or(CoreError::MissingValue)?;
            lib.lock_store()?.set_setting(key, value)?;
            S::ok(true)
        }

        // Short-lived capturers (the Safari extension process) may die before
        // their downloads finish; the app picks the queue up with this.
        "kick_media" => {
            lib.kick_media();
            S::ok(true)
        }
        "fetch_media" => S::ok(lib.fetch_pending_media(req.parse::<Limit>()?.limit)?),
        "retry_media" => {
            let n = lib.lock_store()?.retry_media()?;
            lib.kick_media();
            S::ok(n)
        }
        "media_path" => {
            let file = req.parse::<File>()?.file;
            if !crate::media::is_name(&file) {
                return Err(CoreError::InvalidFileName(file));
            }
            S::ok(lib.media.path(&file))
        }

        other => Err(CoreError::UnknownCmd(other.to_string())),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

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
    #[test]
    fn lookup_suggest_backup() {
        let dir = std::env::temp_dir().join(format!("wm-api2-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let lib = Library::open(&dir.join("lib")).unwrap();
        let f = handle(&lib, r#"{"cmd":"add_folder","name":"filmler"}"#)["data"]["id"].as_i64().unwrap();
        let r = handle(
            &lib,
            &format!(
                r#"{{"cmd":"import_items","folder_id":{f},"tags":["sinema"],"items":[
                    {{"url":"https://x.com/ali/status/1","author_handle":"ali","text":"bir"}}]}}"#
            ),
        );
        assert_eq!(r["ok"], true, "{r}");
        handle(&lib, r#"{"cmd":"import_items","items":[{"url":"https://x.com/ali/status/2","author_handle":"Ali","text":"iki"}]}"#);

        let r = handle(&lib, r#"{"cmd":"search","q":"id:x:2"}"#);
        assert_eq!(r["data"]["total"], 1, "{r}");
        assert_eq!(r["data"]["items"][0]["id"], "x:2");

        // Found by post id even from another URL form; unknown pages are null.
        let r = handle(&lib, r#"{"cmd":"lookup_url","url":"https://twitter.com/ali/status/1?s=20"}"#);
        assert_eq!(r["data"]["id"], "x:1", "{r}");
        assert_eq!(r["data"]["folder"], "filmler");
        assert!(handle(&lib, r#"{"cmd":"lookup_url","url":"https://example.com/yok"}"#)["data"].is_null());

        // Same author (case-insensitive) → that folder.
        let r = handle(&lib, r#"{"cmd":"suggest_folders","id":"x:2"}"#);
        assert_eq!(r["data"][0]["name"], "filmler", "{r}");
        assert_eq!(r["data"][0]["reason"], "author");

        let r = handle(&lib, r#"{"cmd":"ui_set","key":"ui.saved_searches","value":"[]"}"#);
        assert_eq!(r["ok"], true);
        assert_eq!(handle(&lib, r#"{"cmd":"ui_get","key":"ui.saved_searches"}"#)["data"], "[]");
        assert_eq!(handle(&lib, r#"{"cmd":"ui_set","key":"download_videos","value":"0"}"#)["ok"], false);

        // A media file, then two backups: the second copies nothing new.
        let name = lib.media.put_reader(&b"resim"[..], "image/jpeg").unwrap();
        let dest = dir.join("yedek");
        let req = json!({"cmd": "backup", "dest": dest.to_string_lossy()}).to_string();
        let r = handle(&lib, &req);
        assert_eq!(r["ok"], true, "{r}");
        assert_eq!(r["data"]["items"], 2);
        assert_eq!(r["data"]["files_copied"], 1);
        assert!(dest.join("media").join(&name[..2]).join(&name).exists());
        let back = Store::open(&dest.join("library.sqlite")).unwrap();
        assert_eq!(back.get("x:1").unwrap().unwrap().folder_id, Some(f));
        let line = std::fs::read_to_string(dest.join("items.jsonl")).unwrap();
        assert!(line.contains(r#""folder":"filmler""#), "{line}");
        assert_eq!(handle(&lib, &req)["data"]["files_copied"], 0);
        // Never into the library itself.
        let inside = json!({"cmd": "backup", "dest": dir.join("lib/yedek").to_string_lossy()}).to_string();
        assert_eq!(handle(&lib, &inside)["ok"], false);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn link_status() {
        let mut s = Store::open_in_memory().unwrap();
        let l = s.add_link("https://example.com/gitti").unwrap().unwrap();
        assert_eq!(s.links_to_check(10, 3600).unwrap().len(), 1);
        s.set_link_status(l.id, 404, true).unwrap();
        assert!(s.links_to_check(10, 3600).unwrap().is_empty());
        let back = &s.links("", 10, 0).unwrap()[0];
        assert!(back.dead);
        assert_eq!(back.status, Some(404));
    }

    #[test]
    fn handle_json_direct_and_upload_path_safety() {
        let dir = std::env::temp_dir().join(format!("wm-api-sec-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let lib = Library::open(&dir.join("lib")).unwrap();

        let unset: Value = serde_json::from_str(&handle_json(&lib, r#"{"cmd":"ui_get","key":"ui.missing"}"#)).unwrap();
        assert_eq!(unset, json!({ "ok": true, "data": null }));

        let bad_syntax: Value = serde_json::from_str(&handle_json(&lib, r#"{"cmd":bad"#)).unwrap();
        assert_eq!(bad_syntax["ok"], false);

        let arr: Value = serde_json::from_str(&handle_json(&lib, r#"[1, 2, 3]"#)).unwrap();
        assert_eq!(arr, json!({ "ok": false, "error": "cmd eksik" }));

        let dl_json: Value = serde_json::from_str(&handle_json(&lib, r#"{"cmd":"downloads"}"#)).unwrap();
        assert_eq!(dl_json, handle(&lib, r#"{"cmd":"downloads"}"#));

        // Path traversal in chunk ID stays contained inside `.uploads` via hashing.
        let evil_id = "../../outside-escape";
        lib.import_items(
            vec![Item {
                id: evil_id.into(),
                url: "https://www.tiktok.com/@u/video/99".into(),
                media: vec![Media { kind: MediaKind::Video, ..Media::image("https://www.tiktok.com/@u/video/99") }],
                ..Default::default()
            }],
            &[],
            None,
        )
        .unwrap();
        let req = json!({
            "cmd": "upload_chunk",
            "id": evil_id,
            "seq": 0,
            "data": "AAAAGGZ0eXBtcDQy"
        })
        .to_string();
        let r: Value = serde_json::from_str(&handle_json(&lib, &req)).unwrap();
        assert_eq!(r["ok"], true, "{r}");
        assert!(!dir.join("outside-escape.part").exists());
        assert!(dir.join("lib/.uploads").join(format!("{}.part", hash_hex(evil_id.as_bytes()))).exists());

        // Shutdown cleanly waits and checkpoints.
        lib.shutdown();
        let _ = std::fs::remove_dir_all(&dir);
    }
}
