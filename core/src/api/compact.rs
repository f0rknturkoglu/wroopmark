//! Keeps each device's sync log small.
//!
//! A device only ever appends to its own log, so it grows with every edit
//! (an item re-sent ten times while its pictures come in is ten copies of
//! it). Now and then a device rewrites its own log with only what still
//! matters: per item and field group, its newest line; a deletion drops
//! everything older for that item. What the others read from it ends the
//! same either way, because the newest write wins.
//!
//! The others remember how far they read each file by its name, so the
//! short log goes into a file with a new name (`compact-e<N>.jsonl`), the
//! old ones are removed, and from then on new lines go to
//! `<YYYY-MM>-e<N>.jsonl`: a name is never used twice. A device that reads
//! the new file from the start only meets lines it already has.

use std::collections::{HashMap, HashSet};
use std::fs;
use std::io::Write as _;

use super::*;
use crate::db::SyncOp;

/// Below this the log is left alone (tests compact whenever they can).
#[cfg(not(test))]
const MIN_BYTES: u64 = 1 << 20;
#[cfg(test)]
const MIN_BYTES: u64 = 1;

/// The `N` of `…-e<N>.jsonl` / `compact-e<N>.jsonl`, 0 for the first names.
pub(super) fn epoch_of(name: &str) -> u64 {
    let stem = name.strip_suffix(".jsonl").unwrap_or(name);
    stem.rsplit_once("-e").and_then(|(_, n)| n.parse().ok()).unwrap_or(0)
}

/// The file this device appends to now.
pub(super) fn log_name(epoch: u64) -> String {
    let month = chrono::Utc::now().format("%Y-%m");
    if epoch == 0 { format!("{month}.jsonl") } else { format!("{month}-e{epoch}.jsonl") }
}

/// The newest line per item and field group, oldest first.
pub(super) fn compact_ops(mut ops: Vec<SyncOp>) -> Vec<SyncOp> {
    ops.sort_by_key(|o| o.ts);
    let mut covered: HashMap<String, HashSet<&'static str>> = HashMap::new();
    let mut gone: HashSet<String> = HashSet::new();
    let mut kept = vec![];
    for mut op in ops.into_iter().rev() {
        let key = match (&op.setting, &op.id) {
            (Some(s), _) => format!("setting:{s}"),
            (None, Some(id)) => id.clone(),
            (None, None) => continue,
        };
        if gone.contains(&key) {
            continue;
        }
        let seen = covered.entry(key.clone()).or_default();
        if op.setting.is_some() {
            if seen.insert("setting") {
                kept.push(op);
            }
            continue;
        }
        if op.deleted {
            gone.insert(key);
            kept.push(op);
            continue;
        }
        let mut any = false;
        macro_rules! group {
            ($field:ident, $name:literal) => {
                if op.$field.is_some() {
                    if seen.insert($name) {
                        any = true;
                    } else {
                        op.$field = None;
                    }
                }
            };
        }
        group!(content, "content");
        group!(tags, "tags");
        group!(folder, "folder");
        group!(note, "note");
        group!(reviewed, "reviewed");
        group!(ai, "ai");
        group!(highlights, "highlights");
        if any {
            kept.push(op);
        }
    }
    kept.reverse();
    kept
}

impl Library {
    /// This device's epoch: the highest `-e<N>` among its files, or the
    /// one noted in the library if that is higher.
    pub(super) fn log_epoch(&self, dir: &Path) -> Result<u64> {
        let noted = self.lock_store()?.setting("log_epoch")?.and_then(|e| e.parse().ok()).unwrap_or(0);
        let on_disk = fs::read_dir(dir).map(|d| d.flatten().map(|f| epoch_of(&f.file_name().to_string_lossy())).max().unwrap_or(0)).unwrap_or(0);
        Ok(noted.max(on_disk))
    }

    /// Rewrites this device's log when it has grown to twice what it was
    /// after the last time (and past 1 MB). Returns (bytes before, after).
    pub(super) fn compact_log(&self, base: &Path, dev: &str) -> Result<Option<(u64, u64)>> {
        let dir = base.join("ops").join(dev);
        let io = |source: std::io::Error| CoreError::IoPath { path: dir.display().to_string(), source };
        let Ok(entries) = fs::read_dir(&dir) else { return Ok(None) };
        let mut files: Vec<PathBuf> = entries.flatten().map(|e| e.path()).filter(|p| p.extension().is_some_and(|e| e == "jsonl")).collect();
        files.sort();
        let mut before = 0u64;
        for f in &files {
            let Ok(m) = fs::metadata(f) else { return Ok(None) };
            // Not on this device right now (iCloud): another time.
            if super::sync::is_dataless(&m) {
                return Ok(None);
            }
            before += m.len();
        }
        let last: u64 = self.lock_store()?.setting("log_compacted_bytes")?.and_then(|b| b.parse().ok()).unwrap_or(0);
        if before < MIN_BYTES || before < last.saturating_mul(2) {
            return Ok(None);
        }

        let mut ops = vec![];
        for f in &files {
            let text = fs::read(f).map_err(io)?;
            // Only whole lines: a line cut short by a crash is dropped.
            let end = text.iter().rposition(|&b| b == b'\n').map_or(0, |e| e + 1);
            for line in text.get(..end).unwrap_or(&[]).split(|&b| b == b'\n').filter(|l| !l.is_empty()) {
                match serde_json::from_slice::<SyncOp>(line) {
                    Ok(op) => ops.push(op),
                    Err(e) => append_log(&self.root, &format!("sıkıştırma: okunamayan satır ({}): {e}", f.display())),
                }
            }
        }
        let kept = compact_ops(ops);
        let mut out = String::new();
        for op in &kept {
            out.push_str(&serde_json::to_string(op)?);
            out.push('\n');
        }
        let after = out.len() as u64;
        // Not worth making the others read it all again.
        if after * 10 > before * 8 {
            self.lock_store()?.set_setting("log_compacted_bytes", &before.to_string())?;
            return Ok(None);
        }

        let epoch = self.log_epoch(&dir)? + 1;
        let tmp = dir.join(format!(".compact-e{epoch}.tmp"));
        let target = dir.join(format!("compact-e{epoch}.jsonl"));
        {
            let mut f = fs::File::create(&tmp).map_err(io)?;
            f.write_all(out.as_bytes()).map_err(io)?;
            f.sync_all().map_err(io)?;
        }
        fs::rename(&tmp, &target).map_err(io)?;
        {
            let mut store = self.lock_store()?;
            store.set_setting("log_epoch", &epoch.to_string())?;
            store.set_setting("log_compacted_bytes", &after.to_string())?;
        }
        for f in &files {
            let _ = fs::remove_file(f);
        }
        append_log(&self.root, &format!("senkron günlüğü sıkıştırıldı: {before} → {after} bayt ({} satır)", kept.len()));
        Ok(Some((before, after)))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::db::SyncFields;

    fn op(ts: i64, id: &str) -> SyncOp {
        SyncOp { ts, dev: "a".into(), id: Some(id.into()), ..Default::default() }
    }

    #[test]
    fn keeps_the_newest_per_group() {
        let ops = vec![
            SyncOp { tags: Some(vec!["x".into()]), note: Some("eski".into()), ..op(1, "i1") },
            SyncOp { tags: Some(vec!["y".into()]), ..op(2, "i1") },
            SyncOp { ai: Some(SyncFields::default()), ..op(3, "i2") },
            SyncOp { note: Some("n".into()), ..op(4, "i3") },
            SyncOp { deleted: true, ..op(5, "i3") },
            SyncOp { note: Some("geri".into()), ..op(6, "i3") },
            SyncOp { ts: 7, dev: "a".into(), setting: Some("ui.x".into()), value: Some("1".into()), ..Default::default() },
            SyncOp { ts: 8, dev: "a".into(), setting: Some("ui.x".into()), value: Some("2".into()), ..Default::default() },
        ];
        let kept = compact_ops(ops);
        let ts: Vec<i64> = kept.iter().map(|o| o.ts).collect();
        assert_eq!(ts, vec![1, 2, 3, 5, 6, 8]);
        // The first line keeps only its note: its tags were overwritten.
        assert_eq!((kept[0].tags.is_none(), kept[0].note.as_deref()), (true, Some("eski")));
        assert_eq!(kept[5].value.as_deref(), Some("2"));
    }

    #[test]
    fn names_never_repeat() {
        assert_eq!(epoch_of("2026-11.jsonl"), 0);
        assert_eq!(epoch_of("compact-e3.jsonl"), 3);
        assert_eq!(epoch_of("2026-12-e3.jsonl"), 3);
        assert!(log_name(2).ends_with("-e2.jsonl"));
        assert!(!log_name(0).contains("-e"));
    }
}
