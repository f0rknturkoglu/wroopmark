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

use std::collections::HashSet;
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
    /// Pictures in the folder that iCloud has not downloaded here yet, and
    /// (up to 200 of) their paths, for the app to ask iCloud for.
    pub waiting: usize,
    pub fetch: Vec<String>,
    /// Bytes this device's log shrank by, when it was compacted this time.
    pub compacted: u64,
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

fn is_video_file(name: &str) -> bool {
    let ext = name.rsplit('.').next().unwrap_or("").to_ascii_lowercase();
    matches!(ext.as_str(), "mp4" | "mov" | "m4v" | "webm")
}

fn shared_media(base: &Path, name: &str) -> PathBuf {
    base.join("media").join(name.get(..2).unwrap_or("00")).join(name)
}

/// Files the media pass would fetch for this item (see `media_flags_parts`).
fn missing_files(item: &Item) -> usize {
    let quote = item.quote.iter().flat_map(|q| q.media.iter());
    item.media
        .iter()
        .chain(quote)
        .map(|m| {
            usize::from(m.file.is_none() && !m.local_source().is_empty()) + usize::from(m.video_file.is_none() && m.downloadable_video().is_some())
        })
        .sum()
}

/// Where a file of the shared folder is, as far as this device knows.
enum Shared {
    /// On disk, readable now.
    Here,
    /// In the folder but not downloaded: a dataless file, or the
    /// `.name.icloud` placeholder iOS shows for one.
    Remote,
    Missing,
}

fn shared_state(path: &Path) -> Shared {
    match fs::metadata(path) {
        Ok(m) if m.is_file() => {
            if is_dataless(&m) {
                Shared::Remote
            } else {
                Shared::Here
            }
        }
        _ => {
            let placeholder = path.file_name().map(|n| path.with_file_name(format!(".{}.icloud", n.to_string_lossy())));
            if placeholder.is_some_and(|p| p.exists()) { Shared::Remote } else { Shared::Missing }
        }
    }
}

/// A file whose contents are still in the cloud (APFS `SF_DATALESS`).
/// `stat` does not download it; opening it does, and waits.
#[cfg(any(target_os = "macos", target_os = "ios"))]
pub(super) fn is_dataless(m: &fs::Metadata) -> bool {
    #[cfg(target_os = "ios")]
    use std::os::ios::fs::MetadataExt;
    #[cfg(target_os = "macos")]
    use std::os::macos::fs::MetadataExt;
    const SF_DATALESS: u32 = 0x4000_0000;
    m.st_flags() & SF_DATALESS != 0
}

#[cfg(not(any(target_os = "macos", target_os = "ios")))]
pub(super) fn is_dataless(_: &fs::Metadata) -> bool {
    false
}

impl Library {
    fn sync_base(&self) -> Result<Option<PathBuf>> {
        Ok(self.lock_store()?.setting("sync_dir")?.filter(|d| !d.is_empty()).map(PathBuf::from))
    }

    /// This library's device id (made once, kept in the library). A copy of
    /// the library in another place (a restored backup, a test copy) gets
    /// its own id, so two libraries never write the same log.
    pub fn device_id(&self) -> Result<String> {
        let mut store = self.lock_store()?;
        let here = self.root.display().to_string();
        let moved = store.setting("device_root")?.is_some_and(|r| r != here);
        if let Some(id) = store.setting("device_id")?.filter(|_| !moved) {
            if store.setting("device_root")?.is_none() {
                store.set_setting("device_root", &here)?;
            }
            return Ok(id);
        }
        store.set_setting("device_root", &here)?;
        let seed = format!("{}-{}-{}", self.root.display(), std::process::id(), chrono::Utc::now().timestamp_nanos_opt().unwrap_or_default());
        let id = hash_hex(seed.as_bytes()).chars().take(16).collect::<String>();
        store.set_setting("device_id", &id)?;
        Ok(id)
    }

    fn media_mode(&self) -> Result<MediaMode> {
        Ok(MediaMode::parse(&self.lock_store()?.setting("sync_media")?.unwrap_or_default()))
    }

    fn send_videos(&self, mode: MediaMode) -> bool {
        mode == MediaMode::All || !self.videos_enabled()
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
        if !self.videos_enabled() && self.lock_store()?.setting("own_videos_backfill")?.as_deref() != Some("1") {
            let mut store = self.lock_store()?;
            store.set_setting("sync_media_backfill", "1")?;
            store.set_setting("own_videos_backfill", "1")?;
        }
        self.queue_media_out(&base)?;
        self.push(&base, &dev, &mut report)?;
        match self.compact_log(&base, &dev) {
            Ok(Some((before, after))) => report.compacted = before.saturating_sub(after),
            Ok(None) => {}
            Err(e) => append_log(&self.root, &format!("senkron günlüğü sıkıştırılamadı: {e}")),
        }
        self.pull(&base, &dev, &mut report)?;
        let (came, remote) = self.collect_media(&base)?;
        report.media_in += came;
        report.waiting = remote.len();
        report.fetch = remote.iter().take(200).map(|p| p.display().to_string()).collect();
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
        let epoch = self.log_epoch(&dir)?;
        loop {
            let batch = self.lock_store()?.take_dirty(300)?;
            if batch.is_empty() {
                break;
            }
            let ts = now_ms();
            let file = dir.join(super::compact::log_name(epoch));
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

    /// Files of an item this device has and the folder lacks, in this mode.
    fn media_to_send(&self, base: &Path, item: &Item, mode: MediaMode) -> Vec<String> {
        if mode == MediaMode::None {
            return vec![];
        }
        let quote = item.quote.iter().flat_map(|q| q.media.iter());
        let mut out = vec![];
        for m in item.media.iter().chain(quote) {
            let include_video = self.send_videos(mode) || m.downloadable_video().is_none();
            let video = if include_video { m.video_file.as_deref() } else { None };
            for name in [m.file.as_deref(), video].into_iter().flatten() {
                if self.media.contains(name) && matches!(shared_state(&shared_media(base, name)), Shared::Missing) {
                    out.push(name.to_string());
                }
            }
        }
        out
    }

    /// After the media setting changed (or on a library that synced before
    /// media changes were sent), sends again the items whose files the
    /// folder lacks; the push copies the files. At most about 1 GB a round.
    fn queue_media_out(&self, base: &Path) -> Result<()> {
        const BUDGET: u64 = 1 << 30;
        if self.lock_store()?.setting("sync_media_backfill")?.as_deref() != Some("1") {
            return Ok(());
        }
        let mode = self.media_mode()?;
        let ids = self.lock_store()?.media_item_ids()?;
        let (mut queued, mut bytes, mut done) = (vec![], 0u64, true);
        for id in ids {
            let Some(item) = self.lock_store()?.get(&id)? else { continue };
            let files = self.media_to_send(base, &item, mode);
            if files.is_empty() {
                continue;
            }
            if bytes >= BUDGET {
                done = false;
                break;
            }
            bytes += files.iter().filter_map(|f| self.media.file_size(f)).map(|n| u64::try_from(n).unwrap_or(0)).sum::<u64>();
            queued.push(id);
        }
        let mut store = self.lock_store()?;
        store.mark_content_dirty(&queued)?;
        if done {
            store.set_setting("sync_media_backfill", "0")?;
        }
        if !queued.is_empty() {
            append_log(&self.root, &format!("senkron: {} kaydın dosyaları klasöre gidiyor ({} MB)", queued.len(), bytes >> 20));
        }
        Ok(())
    }

    fn copy_media_out(&self, base: &Path, item: &Item, mode: MediaMode) -> usize {
        let mut n = 0;
        let quote = item.quote.iter().flat_map(|q| q.media.iter());
        for m in item.media.iter().chain(quote) {
            let mut files = vec![m.file.as_deref()];
            if self.send_videos(mode) || m.downloadable_video().is_none() {
                files.push(m.video_file.as_deref());
            }
            for name in files.into_iter().flatten() {
                let src = self.media.path(name);
                let dst = shared_media(base, name);
                if src.is_file() && matches!(shared_state(&dst), Shared::Missing) {
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
    /// folder, but only those already on this device: opening a file iCloud
    /// has not downloaded yet blocks until it has, which on a phone with an
    /// empty iCloud cache made one sync take hours. Those are noted and
    /// taken by a later round (`collect_media`) once iCloud has them.
    /// Returns how many files it copied and how many of the item's missing
    /// files are waiting for iCloud rather than for the web.
    fn take_media_in(&self, base: &Path, id: &str, media: &mut [Media]) -> Result<(usize, usize)> {
        let (mut n, mut held) = (0, 0);
        // Low on space (the iPhone app pauses media): note, do not copy.
        let paused = self.media_paused();
        let on_demand = self.videos_on_demand();
        let mut waits = vec![];
        for m in media.iter_mut() {
            // The keys `remember_files` uses for each slot.
            let keys = [m.local_source().to_string(), m.url.clone()];
            // Whether a missing file in each slot sends the item to the web.
            let counts = [true, m.downloadable_video().is_some()];
            for (i, ((slot, key), counts)) in [&mut m.file, &mut m.video_file].into_iter().zip(keys).zip(counts).enumerate() {
                let Some(name) = slot.clone() else { continue };
                // Videos on demand: keep the name only; the app plays the
                // file from the shared folder when it is opened.
                if self.media.contains(&name) || (i == 1 && on_demand) {
                    continue;
                }
                let src = shared_media(base, &name);
                match shared_state(&src) {
                    Shared::Here if !paused && self.copy_in(&src, &name) => {
                        n += 1;
                        continue;
                    }
                    Shared::Remote | Shared::Here if !key.is_empty() => {
                        held += usize::from(counts);
                        waits.push((name, id.to_string(), key));
                    }
                    // Not in the folder yet: the other device may still be
                    // uploading it. Remember the name (the item still goes
                    // to the web meanwhile); `collect_media` takes it later.
                    Shared::Missing if !key.is_empty() => waits.push((name, id.to_string(), key)),
                    _ => {}
                }
                *slot = None;
            }
        }
        if !waits.is_empty() {
            self.lock_store()?.add_media_waits(&waits)?;
        }
        Ok((n, held))
    }

    /// Fills the slots our copy of an item lacks with the files another
    /// device has for the same media URLs.
    fn merge_media(&self, base: &Path, id: &str, theirs: &Item, report: &mut SyncReport) -> Result<bool> {
        let Some(mut ours) = self.lock_store()?.get(id)? else { return Ok(false) };
        let mut changed = self.offer_media(base, id, &mut ours.media, &theirs.media, report)?;
        if let (Some(q), Some(tq)) = (ours.quote.as_mut(), theirs.quote.as_ref()) {
            changed |= self.offer_media(base, id, &mut q.media, &tq.media, report)?;
        }
        if changed {
            self.lock_store()?.set_media(id, &ours.media, ours.quote.as_deref())?;
        }
        Ok(changed)
    }

    fn offer_media(&self, base: &Path, id: &str, ours: &mut [Media], theirs: &[Media], report: &mut SyncReport) -> Result<bool> {
        let mut offered: Vec<Media> = theirs
            .iter()
            .filter_map(|t| {
                let o = ours.iter().find(|o| o.url == t.url)?;
                let mut c = t.clone();
                if o.file.is_some() {
                    c.file = None;
                }
                if o.video_file.is_some() {
                    c.video_file = None;
                }
                (c.file.is_some() || c.video_file.is_some()).then_some(c)
            })
            .collect();
        if offered.is_empty() {
            return Ok(false);
        }
        // Copies what is here; notes what iCloud still has to bring.
        let (n, _) = self.take_media_in(base, id, &mut offered)?;
        report.media_in += n;
        let mut changed = false;
        for c in offered {
            let Some(o) = ours.iter_mut().find(|o| o.url == c.url) else { continue };
            if o.file.is_none() && c.file.is_some() {
                o.file = c.file;
                changed = true;
            }
            if o.video_file.is_none() && c.video_file.is_some() {
                o.video_file = c.video_file;
                changed = true;
            }
        }
        Ok(changed)
    }

    /// Takes the waiting files iCloud has downloaded since. Returns how many
    /// came and the folder paths of those still on their way, so the app
    /// can ask iCloud for them.
    fn collect_media(&self, base: &Path) -> Result<(usize, Vec<PathBuf>)> {
        let waits = self.lock_store()?.media_waits()?;
        if waits.is_empty() || self.media_paused() {
            return Ok((0, vec![]));
        }
        // How long a file may stay absent from the folder before we stop
        // expecting it (the other device's media setting skips it).
        const PATIENCE: i64 = 14 * 24 * 3600;
        let now = crate::text::now();
        let ids: Vec<String> = waits.iter().map(|(_, i, _)| i.clone()).collect();
        let alive = self.lock_store()?.existing_ids(&ids)?;
        let on_demand = self.videos_on_demand();
        let (mut done, mut items, mut remote) = (vec![], vec![], vec![]);
        let mut still: HashSet<String> = HashSet::new();
        let mut came = 0;
        for (file, item, since) in waits {
            let src = shared_media(base, &file);
            match shared_state(&src) {
                _ if !alive.contains(&item) => {}
                // Videos on demand are not copied (the logs, read again when
                // the setting changed, give the item its video's name).
                _ if on_demand && is_video_file(&file) => {}
                Shared::Remote => {
                    remote.push(src);
                    still.insert(item);
                    continue;
                }
                // Already brought in by another line of the log.
                _ if self.media.contains(&file) => items.push(item),
                Shared::Here if self.copy_in(&src, &file) => {
                    came += 1;
                    items.push(item);
                }
                Shared::Missing if now - since < PATIENCE => continue,
                // Never came, or gone from the folder: the usual download.
                _ => items.push(item),
            }
            done.push(file);
        }
        // An item gets its media pass once all its files are here, so the
        // ones still coming are not fetched from the site meanwhile.
        items.retain(|i| !still.contains(i));
        items.dedup();
        self.lock_store()?.end_media_waits(&done, &items)?;
        Ok((came, remote))
    }

    fn videos_on_demand(&self) -> bool {
        self.lock_store().ok().and_then(|s| s.setting("videos_on_demand").ok().flatten()).is_some_and(|v| v == "1")
    }

    /// Videos on demand (the iPhone, to save space) or copied like the
    /// pictures. Turning it on reads the logs again so every video gets its
    /// name without the file; turning it off waits for the missing files.
    pub fn set_videos_on_demand(&self, on: bool) -> Result<()> {
        {
            let mut store = self.lock_store()?;
            store.set_setting("videos_on_demand", if on { "1" } else { "0" })?;
            if on {
                store.reset_cursors()?;
                return Ok(());
            }
        }
        let mut waits = vec![];
        for (id, m) in self.videos()? {
            if let Some(v) = m.video_file.filter(|v| !self.media.contains(v)) {
                waits.push((v, id, m.url));
            }
        }
        self.lock_store()?.add_media_waits(&waits)?;
        Ok(())
    }

    /// Every video slot with a file name, with its item.
    fn videos(&self) -> Result<Vec<(String, Media)>> {
        let ids = self.lock_store()?.media_item_ids()?;
        let mut out = vec![];
        for id in ids {
            let Some(item) = self.lock_store()?.get(&id)? else { continue };
            let quote = item.quote.iter().flat_map(|q| q.media.iter());
            for m in item.media.iter().chain(quote).filter(|m| m.video_file.is_some()) {
                out.push((id.clone(), m.clone()));
            }
        }
        Ok(out)
    }

    /// Removes this device's copies of the videos the shared folder also
    /// has (they play from there again). With `dry_run`, only counts.
    /// Returns (files, bytes).
    pub fn offload_videos(&self, dry_run: bool) -> Result<(usize, u64)> {
        let Some(base) = self.sync_base()? else { return Ok((0, 0)) };
        let (mut files, mut bytes) = (0, 0u64);
        let mut seen = HashSet::new();
        for (_, m) in self.videos()? {
            let Some(v) = m.video_file else { continue };
            if !seen.insert(v.clone()) || !self.media.contains(&v) || matches!(shared_state(&shared_media(&base, &v)), Shared::Missing) {
                continue;
            }
            let size = self.media.file_size(&v).and_then(|n| u64::try_from(n).ok()).unwrap_or(0);
            if dry_run || fs::remove_file(self.media.path(&v)).is_ok() {
                files += 1;
                bytes += size;
            }
        }
        Ok((files, bytes))
    }

    fn copy_in(&self, src: &Path, name: &str) -> bool {
        let dst = self.media.path(name);
        let part = dst.with_extension("part");
        let ok = dst.parent().is_some_and(|p| fs::create_dir_all(p).is_ok()) && fs::copy(src, &part).is_ok() && fs::rename(&part, &dst).is_ok();
        if !ok {
            let _ = fs::remove_file(&part);
        }
        ok
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
            let all: Vec<String> = files.flatten().map(|f| f.file_name().to_string_lossy().to_string()).collect();
            // Files the other device removed (it compacted its log): their
            // places are of no use any more. One iCloud has not brought
            // here yet (`.name.icloud`) is still there.
            let present: Vec<String> =
                all.iter().map(|n| n.strip_prefix('.').and_then(|n| n.strip_suffix(".icloud")).unwrap_or(n).to_string()).collect();
            self.lock_store()?.prune_cursors(&other, &present)?;
            let mut files: Vec<PathBuf> = all.iter().filter(|n| n.ends_with(".jsonl")).map(|n| d.path().join(n)).collect();
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
                let (n, mut held) = self.take_media_in(base, &id, &mut item.media)?;
                report.media_in += n;
                if let Some(q) = item.quote.as_mut() {
                    let (n, h) = self.take_media_in(base, &id, &mut q.media)?;
                    report.media_in += n;
                    held += h;
                }
                let mut store = self.lock_store()?;
                store.upsert_all(std::slice::from_mut(&mut item))?;
                store.apply_remote_extras(&item)?;
                // Everything missing is on its way through iCloud: no need
                // to fetch the same pictures from the sites meanwhile.
                if held > 0 && held == missing_files(&item) {
                    store.hold_media(&id)?;
                }
                store.stamp(&id, "content", ts, dev)?;
                changed = true;
            } else if newer(ts, dev, deleted.as_ref()) {
                // Files are named by their contents, so they never conflict:
                // a line that lost on the rest still brings the files we
                // lack (the Mac's videos while the phone kept re-sending the
                // item as its pictures came in).
                changed |= self.merge_media(base, &id, &item, report)?;
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
        if let Some(h) = &op.highlights
            && take(&mut store, "highlights")?
        {
            store.set_highlights(&id, h)?;
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
            "videos_on_demand": store.setting("videos_on_demand")?.as_deref() == Some("1"),
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
        "videos_on_demand" => {
            #[derive(Deserialize)]
            struct On {
                on: bool,
            }
            req.parse::<On>().and_then(|o| lib.set_videos_on_demand(o.on)).and_then(|()| S::ok(true))
        }
        "offload_videos" => {
            #[derive(Deserialize)]
            struct Dry {
                #[serde(default)]
                dry_run: bool,
            }
            req.parse::<Dry>().and_then(|d| lib.offload_videos(d.dry_run)).and_then(|(files, bytes)| S::ok(json!({"files": files, "bytes": bytes})))
        }
        "sync_set_media" => {
            #[derive(Deserialize)]
            struct M {
                media: String,
            }
            req.parse::<M>().and_then(|m| {
                let mut store = lib.lock_store()?;
                store.set_setting("sync_media", &m.media)?;
                // Files that were not sent under the old setting go now.
                store.set_setting("sync_media_backfill", "1")?;
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
    fn compacted_log_reaches_everyone() {
        let root = std::env::temp_dir().join(format!("wm-compact-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        let shared = root.join("shared");
        let a = Library::open(&root.join("a")).unwrap_or_else(|_| std::process::abort());
        let b = Library::open(&root.join("b")).unwrap_or_else(|_| std::process::abort());
        call(
            &a,
            json!({"cmd": "import_items", "items": [
            {"platform": "web", "url": "https://example.com/c1", "text": "bir"},
            {"platform": "web", "url": "https://example.com/c2", "text": "iki"}]}),
        );
        let one = item_id_for_url("https://example.com/c1").1;
        let two = item_id_for_url("https://example.com/c2").1;
        call(&a, json!({"cmd": "sync_enable", "dir": shared}));
        call(&b, json!({"cmd": "sync_enable", "dir": shared}));

        // Many edits; B reads now and then, so it holds places in files
        // that compaction removes.
        let mut compactions = 0;
        for i in 0..40 {
            call(&a, json!({"cmd": "set_note", "id": one, "note": format!("not {i}")}));
            if i == 20 {
                call(&a, json!({"cmd": "delete", "id": two}));
            }
            let r = call(&a, json!({"cmd": "sync_now"}));
            if r.get("compacted").and_then(Value::as_u64).unwrap_or(0) > 0 {
                compactions += 1;
            }
            if i % 7 == 0 {
                call(&b, json!({"cmd": "sync_now"}));
            }
        }
        assert!(compactions >= 2, "{compactions}");
        // A's later lines go to new names, never a name B already read.
        let dev = a.device_id().unwrap_or_default();
        let names: Vec<String> = fs::read_dir(shared.join("ops").join(&dev))
            .map(|d| d.flatten().map(|f| f.file_name().to_string_lossy().to_string()).collect())
            .unwrap_or_default();
        assert!(names.iter().all(|n| n.contains("-e")), "{names:?}");

        call(&b, json!({"cmd": "sync_now"}));
        assert_eq!(call(&b, json!({"cmd": "get", "id": one})).get("note"), Some(&json!("not 39")));
        assert!(call(&b, json!({"cmd": "get", "id": two})).is_null());
        // B's places in A's removed files are forgotten.
        let stale = b.lock_store().map(|s| s.cursor(&format!("{dev}/{}", super::super::compact::log_name(0))).unwrap_or(0)).unwrap_or(0);
        assert_eq!(stale, 0);

        // A device that comes later gets the same from the short log.
        let c = Library::open(&root.join("c")).unwrap_or_else(|_| std::process::abort());
        call(&c, json!({"cmd": "sync_enable", "dir": shared}));
        assert_eq!(call(&c, json!({"cmd": "get", "id": one})).get("note"), Some(&json!("not 39")));
        assert!(call(&c, json!({"cmd": "get", "id": two})).is_null());
        a.shutdown();
        b.shutdown();
        c.shutdown();
        let _ = fs::remove_dir_all(&root);
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
        // A copy of A's library elsewhere is another device.
        let a_id = a.device_id().unwrap_or_default();
        a.shutdown();
        b.shutdown();
        drop(a);
        let _ = fs::create_dir_all(root.join("a-copy"));
        let _ = fs::copy(root.join("a/library.sqlite"), root.join("a-copy/library.sqlite"));
        let copy = Library::open(&root.join("a-copy")).unwrap_or_else(|_| std::process::abort());
        let copy_id = copy.device_id().unwrap_or_default();
        assert!(!copy_id.is_empty() && copy_id != a_id);
        copy.shutdown();
        let _ = fs::remove_dir_all(&root);
    }
    /// A picture iCloud has not downloaded yet must not hold up the sync;
    /// a later round takes it once it is there.
    #[test]
    fn remote_media_waits_for_the_media_pass() {
        let root = std::env::temp_dir().join(format!("wm-sync-remote-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        let shared = root.join("shared");
        let a = Library::open(&root.join("a")).unwrap_or_else(|_| std::process::abort());
        let b = Library::open(&root.join("b")).unwrap_or_else(|_| std::process::abort());
        let pic = a.media.put(b"still in the cloud", "jpg").unwrap_or_default();
        call(
            &a,
            json!({"cmd": "import_items", "items": [
            {"platform": "web", "url": "https://example.com/r", "text": "uzakta", "media": [{"kind": "image", "url": "https://e.invalid/p.jpg", "file": pic}]}]}),
        );
        call(&a, json!({"cmd": "sync_enable", "dir": shared, "media": "images"}));

        // What the iPhone shows for a file it has not downloaded.
        let real = shared_media(&shared, &pic);
        let placeholder = real.with_file_name(format!(".{pic}.icloud"));
        assert!(fs::rename(&real, &placeholder).is_ok());
        let r = call(&b, json!({"cmd": "sync_enable", "dir": shared}));
        assert_eq!(r.get("applied"), Some(&json!(1)), "{r}");
        assert_eq!(r.get("media_in"), Some(&json!(0)));
        assert_eq!(r.get("waiting"), Some(&json!(1)));
        assert_eq!(r.pointer("/fetch/0"), Some(&json!(real.display().to_string())));
        b.wait_media();
        let id = item_id_for_url("https://example.com/r").1;
        let got = call(&b, json!({"cmd": "get", "id": id}));
        assert!(got.pointer("/media/0/file").is_none_or(Value::is_null), "{got}");
        // Not fetched from the site meanwhile: it is coming through iCloud.
        assert!(b.lock_store().and_then(|s| Ok(s.pending_media(10)?)).is_ok_and(|p| p.is_empty()));

        // iCloud delivers it; the next round takes it, and no longer waits.
        assert!(fs::rename(&placeholder, &real).is_ok());
        let r = call(&b, json!({"cmd": "sync_now"}));
        assert_eq!(r.get("media_in"), Some(&json!(1)), "{r}");
        assert_eq!(r.get("waiting"), Some(&json!(0)));
        b.wait_media();
        let got = call(&b, json!({"cmd": "get", "id": id}));
        assert_eq!(got.pointer("/media/0/file"), Some(&json!(pic)), "{got}");
        assert!(b.media.contains(&pic));
        a.shutdown();
        b.shutdown();
        let _ = fs::remove_dir_all(&root);
    }
    /// Videos skipped under "images" go to the folder once the setting is
    /// "all", and reach the other device; so does a file downloaded later.
    #[test]
    fn media_setting_change_sends_old_files() {
        let root = std::env::temp_dir().join(format!("wm-sync-videos-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        let shared = root.join("shared");
        let a = Library::open(&root.join("a")).unwrap_or_else(|_| std::process::abort());
        let b = Library::open(&root.join("b")).unwrap_or_else(|_| std::process::abort());
        let poster = a.media.put(b"poster", "jpg").unwrap_or_default();
        let video = a.media.put(b"video", "mp4").unwrap_or_default();
        call(
            &a,
            json!({"cmd": "import_items", "items": [
            {"platform": "web", "url": "https://example.com/v", "text": "video", "media": [
                {"kind": "video", "url": "https://e.invalid/v.mp4", "thumb_url": "https://e.invalid/v.jpg", "file": poster, "video_file": video}]}]}),
        );
        call(&a, json!({"cmd": "sync_enable", "dir": shared, "media": "images"}));
        assert!(matches!(shared_state(&shared_media(&shared, &poster)), Shared::Here));
        assert!(matches!(shared_state(&shared_media(&shared, &video)), Shared::Missing));
        call(&b, json!({"cmd": "sync_enable", "dir": shared}));

        call(&a, json!({"cmd": "sync_set_media", "media": "all"}));
        let r = call(&a, json!({"cmd": "sync_now"}));
        assert_eq!(r.get("pushed"), Some(&json!(1)), "{r}");
        assert!(matches!(shared_state(&shared_media(&shared, &video)), Shared::Here));
        // Once is enough.
        assert_eq!(call(&a, json!({"cmd": "sync_now"})).get("pushed"), Some(&json!(0)));

        // B sends the item again after A's line (as the phone does while
        // its pictures come in): its line wins, the video still comes.
        let id = item_id_for_url("https://example.com/v").1;
        std::thread::sleep(Duration::from_millis(5));
        assert!(b.lock_store().and_then(|mut s| Ok(s.mark_content_dirty(std::slice::from_ref(&id))?)).is_ok());
        let r = call(&b, json!({"cmd": "sync_now"}));
        assert_eq!(r.get("pushed"), Some(&json!(1)), "{r}");
        assert_eq!(r.get("media_in"), Some(&json!(1)), "{r}");
        assert_eq!(call(&b, json!({"cmd": "get", "id": id})).pointer("/media/0/video_file"), Some(&json!(video)));
        assert!(b.media.contains(&video));
        a.shutdown();
        b.shutdown();
        let _ = fs::remove_dir_all(&root);
    }
    /// A file the other device has not uploaded yet (not in the folder at
    /// all) is still expected, and taken when it shows up.
    #[test]
    fn media_not_yet_uploaded_comes_later() {
        let root = std::env::temp_dir().join(format!("wm-sync-late-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        let shared = root.join("shared");
        let a = Library::open(&root.join("a")).unwrap_or_else(|_| std::process::abort());
        let b = Library::open(&root.join("b")).unwrap_or_else(|_| std::process::abort());
        let pic = a.media.put(b"uploading", "jpg").unwrap_or_default();
        call(
            &a,
            json!({"cmd": "import_items", "items": [
            {"platform": "web", "url": "https://example.com/l", "text": "geç", "media": [{"kind": "image", "url": "https://e.invalid/l.jpg", "file": pic}]}]}),
        );
        call(&a, json!({"cmd": "sync_enable", "dir": shared, "media": "images"}));
        let real = shared_media(&shared, &pic);
        let aside = root.join("aside.jpg");
        assert!(fs::rename(&real, &aside).is_ok());

        call(&b, json!({"cmd": "sync_enable", "dir": shared}));
        b.wait_media();
        let id = item_id_for_url("https://example.com/l").1;
        assert!(call(&b, json!({"cmd": "get", "id": id})).pointer("/media/0/file").is_none_or(Value::is_null));
        assert_eq!(call(&b, json!({"cmd": "sync_now"})).get("media_in"), Some(&json!(0)));

        assert!(fs::rename(&aside, &real).is_ok());
        let r = call(&b, json!({"cmd": "sync_now"}));
        assert_eq!(r.get("media_in"), Some(&json!(1)), "{r}");
        b.wait_media();
        assert_eq!(call(&b, json!({"cmd": "get", "id": id})).pointer("/media/0/file"), Some(&json!(pic)));
        a.shutdown();
        b.shutdown();
        let _ = fs::remove_dir_all(&root);
    }
    /// Videos on demand: the phone keeps the name, not the file; offloading
    /// removes the copies the folder also has; turning it off brings them.
    #[test]
    fn videos_on_demand_and_offload() {
        let root = std::env::temp_dir().join(format!("wm-sync-ondemand-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        let shared = root.join("shared");
        let a = Library::open(&root.join("a")).unwrap_or_else(|_| std::process::abort());
        let b = Library::open(&root.join("b")).unwrap_or_else(|_| std::process::abort());
        let poster = a.media.put(b"poster", "jpg").unwrap_or_default();
        let video = a.media.put(b"a video file", "mp4").unwrap_or_default();
        call(
            &a,
            json!({"cmd": "import_items", "items": [
            {"platform": "web", "url": "https://example.com/od", "text": "video", "media": [
                {"kind": "video", "url": "https://e.invalid/od.mp4", "thumb_url": "https://e.invalid/od.jpg", "file": poster, "video_file": video}]}]}),
        );
        call(&a, json!({"cmd": "sync_enable", "dir": shared, "media": "all"}));
        call(&b, json!({"cmd": "sync_enable", "dir": shared}));
        assert!(b.media.contains(&video));
        let id = item_id_for_url("https://example.com/od").1;

        // Offload: the copy goes, the name stays, the next sync does not copy it back.
        call(&b, json!({"cmd": "videos_on_demand", "on": true}));
        let dry = call(&b, json!({"cmd": "offload_videos", "dry_run": true}));
        assert_eq!(dry.get("files"), Some(&json!(1)), "{dry}");
        assert!(b.media.contains(&video));
        call(&b, json!({"cmd": "offload_videos"}));
        assert!(!b.media.contains(&video));
        call(&b, json!({"cmd": "sync_now"}));
        assert!(!b.media.contains(&video));
        assert_eq!(call(&b, json!({"cmd": "get", "id": id})).pointer("/media/0/video_file"), Some(&json!(video)));
        assert!(b.media.contains(&poster));

        // A new device with the setting on gets the name and no file.
        let c = Library::open(&root.join("c")).unwrap_or_else(|_| std::process::abort());
        call(&c, json!({"cmd": "videos_on_demand", "on": true}));
        call(&c, json!({"cmd": "sync_enable", "dir": shared}));
        assert_eq!(call(&c, json!({"cmd": "get", "id": id})).pointer("/media/0/video_file"), Some(&json!(video)));
        assert!(!c.media.contains(&video));

        // Off again: the video comes back.
        call(&b, json!({"cmd": "videos_on_demand", "on": false}));
        let r = call(&b, json!({"cmd": "sync_now"}));
        assert_eq!(r.get("media_in"), Some(&json!(1)), "{r}");
        assert!(b.media.contains(&video));
        for lib in [&a, &b, &c] {
            lib.shutdown();
        }
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn own_videos_on_phone_reach_sync_folder() {
        let root = std::env::temp_dir().join(format!("wm-sync-own-vid-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        let shared = root.join("shared");
        let a = Library::open(&root.join("a")).unwrap_or_else(|_| std::process::abort());
        let b = Library::open(&root.join("b")).unwrap_or_else(|_| std::process::abort());
        call(&a, json!({"cmd": "set_settings", "download_videos": false}));
        call(&a, json!({"cmd": "sync_enable", "dir": shared, "name": "iPhone", "media": "images"}));
        call(
            &a,
            json!({"cmd": "import_items", "items": [
                {"platform": "tiktok", "url": "https://www.tiktok.com/@a/video/456", "text": "tarif",
                 "media": [{"kind": "video", "url": "https://v.example/456.mp4"}]}]}),
        );
        let vid = root.join("screen.mov");
        let _ = fs::write(&vid, b"not really a movie");
        assert_eq!(call(&a, json!({"cmd": "attach_file", "id": "tiktok:456", "path": vid})), json!(true));
        let r = call(&a, json!({"cmd": "sync_now"}));
        assert!(r.get("media_out").and_then(Value::as_u64).unwrap_or(0) >= 1, "{r}");

        call(&b, json!({"cmd": "sync_enable", "dir": shared, "name": "New iPhone"}));
        let got = call(&b, json!({"cmd": "get", "id": "tiktok:456"}));
        let vf = got.pointer("/media/0/video_file").and_then(Value::as_str);
        assert!(vf.is_some_and(|f| f.ends_with(".mov") && b.media.contains(f)), "{got}");
        a.shutdown();
        b.shutdown();
        let _ = fs::remove_dir_all(&root);
    }
}
