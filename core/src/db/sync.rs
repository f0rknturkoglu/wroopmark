//! Store side of sync: what changed (`sync_dirty`, filled by triggers), the
//! log line for an item, and per-field last-writer-wins bookkeeping
//! (`sync_fields`).

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

use super::*;

/// Field groups that travel separately, so two devices editing different
/// things of one item (tags here, the note there) both keep their change.
pub const SYNC_FIELDS: [&str; 6] = ["content", "tags", "folder", "note", "reviewed", "ai"];

/// The on-device summary and tag ideas.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct SyncFields {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub summary: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub tags: Vec<String>,
}

/// One line of a device's log. Only the groups that changed are present.
/// Empty strings mean "none" (no folder, no note).
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct SyncOp {
    /// Milliseconds since 1970; with `dev`, orders writes.
    pub ts: i64,
    pub dev: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub content: Option<Item>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tags: Option<Vec<String>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub folder: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub note: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reviewed: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ai: Option<SyncFields>,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub deleted: bool,
    /// A `ui.` setting (saved searches…) and its value.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub setting: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub value: Option<String>,
}

impl Store {
    pub fn sync_enabled(&self) -> Result<bool> {
        Ok(self.conn.query_row("SELECT enabled FROM sync_state WHERE id = 1", [], |r| r.get(0)).optional()?.unwrap_or(false))
    }

    /// Turns tracking on or off. Turning it on notes everything once, so
    /// the first push carries the whole library.
    pub fn set_sync_enabled(&mut self, on: bool) -> Result<()> {
        let tx = self.write()?;
        tx.execute("UPDATE sync_state SET enabled = ?1, applying = 0 WHERE id = 1", [on])?;
        if on {
            for f in SYNC_FIELDS {
                tx.execute("INSERT OR IGNORE INTO sync_dirty SELECT id, ?1 FROM items", [f])?;
            }
            tx.execute("INSERT OR IGNORE INTO sync_dirty SELECT 'setting:' || key, 'setting' FROM settings WHERE key LIKE 'ui.%'", [])?;
        } else {
            tx.execute("DELETE FROM sync_dirty", [])?;
        }
        tx.commit()?;
        Ok(())
    }

    /// While set, triggers note nothing (remote changes being applied).
    pub fn set_applying(&mut self, on: bool) -> Result<()> {
        self.conn.execute("UPDATE sync_state SET applying = ?1 WHERE id = 1", [on])?;
        Ok(())
    }

    pub fn dirty_count(&self) -> Result<i64> {
        Ok(self.conn.query_row("SELECT count(DISTINCT item) FROM sync_dirty", [], |r| r.get(0))?)
    }

    /// Up to `limit` changed items with their changed groups.
    pub fn take_dirty(&self, limit: i64) -> Result<Vec<(String, Vec<String>)>> {
        let mut stmt = self.conn.prepare_cached(
            "SELECT item, field FROM sync_dirty WHERE item IN (SELECT DISTINCT item FROM sync_dirty ORDER BY item LIMIT ?1) ORDER BY item",
        )?;
        let mut out: BTreeMap<String, Vec<String>> = BTreeMap::new();
        for row in stmt.query_map([limit], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)))? {
            let (item, field) = row?;
            out.entry(item).or_default().push(field);
        }
        Ok(out.into_iter().collect())
    }

    /// Forgets the notes once their lines are written, and records our own
    /// writes so older remote lines cannot undo them.
    pub fn sync_written(&mut self, done: &[(String, Vec<String>)], ts: i64, dev: &str) -> Result<()> {
        let tx = self.write()?;
        {
            let mut del = tx.prepare_cached("DELETE FROM sync_dirty WHERE item = ?1 AND field = ?2")?;
            let mut rec = tx.prepare_cached("INSERT OR REPLACE INTO sync_fields(item, field, ts, dev) VALUES (?1, ?2, ?3, ?4)")?;
            for (item, fields) in done {
                for f in fields {
                    del.execute([item, f])?;
                    rec.execute(params![item, f, ts, dev])?;
                }
            }
        }
        tx.commit()?;
        Ok(())
    }

    /// The log line for an item's changed groups, from its current state.
    /// `None` when the item is gone (and no deletion was noted).
    pub fn sync_op(&self, id: &str, fields: &[String], ts: i64, dev: &str) -> Result<Option<SyncOp>> {
        let mut op = SyncOp { ts, dev: dev.to_string(), id: Some(id.to_string()), ..Default::default() };
        if fields.iter().any(|f| f == "deleted") {
            op.deleted = true;
            return Ok(Some(op));
        }
        let Some(item) = self.get(id)? else { return Ok(None) };
        let row: (Option<i64>, Option<String>) = self.conn.query_row(
            "SELECT i.reviewed_at, f.name FROM items i LEFT JOIN folders f ON f.id = i.folder_id WHERE i.id = ?1",
            [id],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )?;
        for f in fields {
            match f.as_str() {
                "content" => {
                    let mut c = item.clone();
                    c.tags = vec![];
                    c.note = None;
                    c.folder_id = None;
                    c.summary = None;
                    c.ai_tags = vec![];
                    c.raw = None;
                    c.snapshot = None;
                    c.video_tries = 0;
                    c.extra = c.extra.map(|e| e.chars().take(20_000).collect());
                    op.content = Some(c);
                }
                "tags" => op.tags = Some(item.tags.clone()),
                "folder" => op.folder = Some(row.1.clone().unwrap_or_default()),
                "note" => op.note = Some(item.note.clone().unwrap_or_default()),
                "reviewed" => op.reviewed = Some(row.0.is_some()),
                "ai" => op.ai = Some(SyncFields { summary: item.summary.clone(), tags: item.ai_tags.clone() }),
                _ => {}
            }
        }
        Ok(Some(op))
    }

    /// When a group was last written, and by which device.
    pub fn field_stamp(&self, item: &str, field: &str) -> Result<Option<(i64, String)>> {
        Ok(self
            .conn
            .query_row("SELECT ts, dev FROM sync_fields WHERE item = ?1 AND field = ?2", [item, field], |r| Ok((r.get(0)?, r.get(1)?)))
            .optional()?)
    }

    /// The newest write to any group of the item.
    pub fn newest_stamp(&self, item: &str) -> Result<Option<(i64, String)>> {
        Ok(self
            .conn
            .query_row("SELECT ts, dev FROM sync_fields WHERE item = ?1 ORDER BY ts DESC, dev DESC LIMIT 1", [item], |r| Ok((r.get(0)?, r.get(1)?)))
            .optional()?)
    }

    pub fn stamp(&mut self, item: &str, field: &str, ts: i64, dev: &str) -> Result<()> {
        self.conn.execute("INSERT OR REPLACE INTO sync_fields(item, field, ts, dev) VALUES (?1, ?2, ?3, ?4)", params![item, field, ts, dev])?;
        Ok(())
    }

    pub fn cursor(&self, file: &str) -> Result<u64> {
        let n: Option<i64> = self.conn.query_row("SELECT offset FROM sync_cursor WHERE file = ?1", [file], |r| r.get(0)).optional()?;
        Ok(n.and_then(|n| u64::try_from(n).ok()).unwrap_or(0))
    }

    pub fn set_cursor(&mut self, file: &str, offset: u64) -> Result<()> {
        let offset = i64::try_from(offset).unwrap_or(i64::MAX);
        self.conn.execute("INSERT OR REPLACE INTO sync_cursor(file, offset) VALUES (?1, ?2)", params![file, offset])?;
        Ok(())
    }

    /// Writes the parts of a remote item that `upsert` leaves alone.
    pub fn apply_remote_extras(&mut self, item: &Item) -> Result<()> {
        let pk = pk_of(&self.conn, &item.id)?;
        self.conn.execute("UPDATE items SET stub = ?2, ocr = coalesce(?3, ocr) WHERE pk = ?1", params![pk, item.stub, item.ocr])?;
        reindex_item(&self.conn, pk)
    }

    /// Notes files of remote items that are in the sync folder but not on
    /// this device yet: (store name, item id, the URL key `known_file` uses).
    pub fn add_media_waits(&mut self, rows: &[(String, String, String)]) -> Result<()> {
        let tx = self.write()?;
        {
            let mut known = tx.prepare_cached("INSERT OR REPLACE INTO media_files(url, file) VALUES (?1, ?2)")?;
            let mut wait = tx.prepare_cached(
                "INSERT INTO sync_media_wait(file, item, since) VALUES (?1, ?2, ?3) ON CONFLICT(file) DO UPDATE SET item = excluded.item",
            )?;
            let now = crate::text::now();
            for (file, item, url) in rows {
                known.execute([url, file])?;
                wait.execute(params![file, item, now])?;
            }
        }
        tx.commit()?;
        Ok(())
    }

    /// Items that have pictures or videos.
    pub fn media_item_ids(&self) -> Result<Vec<String>> {
        let mut stmt = self.conn.prepare_cached("SELECT id FROM items WHERE has_image = 1 OR has_video = 1 ORDER BY saved_at DESC")?;
        let ids = stmt.query_map([], |r| r.get(0))?.collect::<rusqlite::Result<_>>()?;
        Ok(ids)
    }

    /// Sends these items' content again at the next push.
    pub fn mark_content_dirty(&mut self, ids: &[String]) -> Result<()> {
        let tx = self.write()?;
        {
            let mut stmt = tx.prepare_cached("INSERT OR IGNORE INTO sync_dirty VALUES (?1, 'content')")?;
            for id in ids {
                stmt.execute([id])?;
            }
        }
        tx.commit()?;
        Ok(())
    }

    /// Keeps an item out of the media pass while its files come by iCloud.
    pub fn hold_media(&mut self, id: &str) -> Result<()> {
        self.conn.execute("UPDATE items SET media_pending = 0 WHERE id = ?1", [id])?;
        Ok(())
    }

    /// (store name, item id, noted at) of every file still waiting.
    pub fn media_waits(&self) -> Result<Vec<(String, String, i64)>> {
        let mut stmt = self.conn.prepare_cached("SELECT file, item, since FROM sync_media_wait ORDER BY item")?;
        let rows = stmt.query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))?.collect::<rusqlite::Result<_>>()?;
        Ok(rows)
    }

    /// Drops these waits; the items get a media pass, which finds the files
    /// that came by their URL.
    pub fn end_media_waits(&mut self, files: &[String], items: &[String]) -> Result<()> {
        let tx = self.write()?;
        {
            let mut drop = tx.prepare_cached("DELETE FROM sync_media_wait WHERE file = ?1")?;
            for f in files {
                drop.execute([f])?;
            }
            let mut pending = tx.prepare_cached("UPDATE items SET media_pending = 1 WHERE id = ?1")?;
            for id in items {
                pending.execute([id])?;
            }
        }
        tx.commit()?;
        Ok(())
    }
}
