//! Store parts added in v0.2 / v0.3: rules, archive stubs, vectors, the
//! on-device summary, and duplicate candidates.

use std::collections::{HashMap, HashSet};

use serde::Deserialize;

use super::*;

/// A saved search plus what to do with new items that match it.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Rule {
    pub id: i64,
    pub query: String,
    #[serde(default)]
    pub tag: Option<String>,
    #[serde(default)]
    pub folder_id: Option<i64>,
    #[serde(default)]
    pub folder_name: Option<String>,
    pub enabled: bool,
    #[serde(default)]
    pub created_at: i64,
}

/// Items that look like the same thing saved twice, and why.
#[derive(Debug, Clone, Serialize)]
pub struct DuplicateGroup {
    pub reason: String,
    pub items: Vec<Item>,
}

/// How far archive stubs have been filled in.
#[derive(Debug, Clone, Default, Serialize)]
pub struct StubInfo {
    pub pending: i64,
    pub failed: i64,
}

/// A stub is tried this many times before it stays a bare link.
const STUB_TRIES: i64 = 3;

fn read_rule(r: &Row) -> rusqlite::Result<Rule> {
    Ok(Rule {
        id: r.get(0)?,
        query: r.get(1)?,
        tag: r.get(2)?,
        folder_id: r.get(3)?,
        enabled: r.get(4)?,
        created_at: r.get(5)?,
        folder_name: r.get(6)?,
    })
}

const RULE_COLS: &str = "r.id, r.query, r.tag, r.folder_id, r.enabled, r.created_at, f.name";

impl Store {
    // --- Rules --------------------------------------------------------------

    pub fn rules(&self) -> Result<Vec<Rule>> {
        let mut stmt = self.conn.prepare(&format!("SELECT {RULE_COLS} FROM rules r LEFT JOIN folders f ON f.id = r.folder_id ORDER BY r.id"))?;
        Ok(stmt.query_map([], read_rule)?.collect::<rusqlite::Result<_>>()?)
    }

    pub fn rule(&self, id: i64) -> Result<Option<Rule>> {
        Ok(self
            .conn
            .query_row(&format!("SELECT {RULE_COLS} FROM rules r LEFT JOIN folders f ON f.id = r.folder_id WHERE r.id = ?1"), [id], read_rule)
            .optional()?)
    }

    pub fn add_rule(&mut self, query: &str, tag: Option<&str>, folder_id: Option<i64>) -> Result<Rule> {
        let tag = tag.map(str::trim).filter(|t| !t.is_empty());
        self.conn.execute(
            "INSERT INTO rules(query, tag, folder_id, enabled, created_at) VALUES (?1, ?2, ?3, 1, ?4)",
            params![query.trim(), tag, folder_id, now()],
        )?;
        let id = self.conn.last_insert_rowid();
        self.rule(id)?.ok_or(StoreError::EmptyResult)
    }

    pub fn update_rule(&mut self, id: i64, query: &str, tag: Option<&str>, folder_id: Option<i64>, enabled: bool) -> Result<()> {
        let tag = tag.map(str::trim).filter(|t| !t.is_empty());
        self.conn.execute(
            "UPDATE rules SET query = ?2, tag = ?3, folder_id = ?4, enabled = ?5 WHERE id = ?1",
            params![id, query.trim(), tag, folder_id, enabled],
        )?;
        Ok(())
    }

    pub fn delete_rule(&mut self, id: i64) -> Result<()> {
        self.conn.execute("DELETE FROM rules WHERE id = ?1", [id])?;
        Ok(())
    }

    /// Ids of the items matching `q`, best first, at most `limit`.
    pub fn matching_ids(&self, q: &Query, limit: i64) -> Result<Vec<String>> {
        let (from, where_sql, order, mut args) = Self::item_query(q, Sort::Default);
        args.push(limit.into());
        let mut stmt = self.conn.prepare(&format!("SELECT i.id FROM {from} {where_sql} ORDER BY {order} LIMIT ?"))?;
        Ok(stmt.query_map(params_from_iter(&args), |r| r.get(0))?.collect::<rusqlite::Result<_>>()?)
    }

    pub fn count_matching(&self, q: &Query) -> Result<i64> {
        let (from, where_sql, _, args) = Self::item_query(q, Sort::Default);
        Ok(self.conn.query_row(&format!("SELECT count(*) FROM {from} {where_sql}"), params_from_iter(&args), |r| r.get(0))?)
    }

    /// Runs one rule over `within` (new items), or over the whole library.
    /// The folder only goes to items that have none: a folder picked at save
    /// time, or by hand, wins. Returns how many items matched.
    pub fn apply_rule(&mut self, rule: &Rule, within: Option<&[String]>) -> Result<usize> {
        let mut q = Query::parse(&rule.query);
        if q == Query::default() {
            return Ok(0);
        }
        if let Some(ids) = within {
            if ids.is_empty() {
                return Ok(0);
            }
            q.ids = ids.to_vec();
        }
        let ids = self.matching_ids(&q, 100_000)?;
        if ids.is_empty() {
            return Ok(0);
        }
        if let Some(tag) = rule.tag.as_deref() {
            self.edit_tags(&ids, &[tag.to_string()], &[])?;
        }
        if let Some(folder) = rule.folder_id {
            let tx = self.write()?;
            {
                let mut stmt = tx.prepare_cached("UPDATE items SET folder_id = ?1 WHERE id = ?2 AND folder_id IS NULL")?;
                for id in &ids {
                    stmt.execute(params![folder, id])?;
                }
            }
            tx.commit()?;
        }
        Ok(ids.len())
    }

    /// Runs every enabled rule over these (newly saved) items.
    pub fn apply_rules(&mut self, ids: &[String]) -> Result<usize> {
        if ids.is_empty() {
            return Ok(0);
        }
        let rules: Vec<Rule> = self.rules()?.into_iter().filter(|r| r.enabled).collect();
        let mut n = 0;
        for rule in &rules {
            n += self.apply_rule(rule, Some(ids))?;
        }
        Ok(n)
    }

    /// The folder with this name (any case), made with its parents if needed.
    pub fn ensure_folder(&mut self, name: &str) -> Result<i64> {
        let mut id = 0;
        let mut path = String::new();
        for part in name.split('/').map(str::trim).filter(|p| !p.is_empty()) {
            if !path.is_empty() {
                path.push('/');
            }
            path.push_str(part);
            let found: Option<i64> = self.conn.query_row("SELECT id FROM folders WHERE lower(name) = lower(?1)", [&path], |r| r.get(0)).optional()?;
            id = match found {
                Some(f) => f,
                None => self.add_folder(&path)?.id,
            };
        }
        if id == 0 { Err(StoreError::EmptyFolderName) } else { Ok(id) }
    }

    // --- Archive stubs -------------------------------------------------------

    /// Which of these ids are already in the library.
    pub fn existing_ids(&self, ids: &[String]) -> Result<HashSet<String>> {
        let mut out = HashSet::new();
        let mut stmt = self.conn.prepare_cached("SELECT 1 FROM items WHERE id = ?1")?;
        for id in ids {
            if stmt.exists([id])? {
                out.insert(id.clone());
            }
        }
        Ok(out)
    }

    pub fn mark_stubs(&mut self, ids: &[String]) -> Result<()> {
        let tx = self.write()?;
        {
            let mut stmt = tx.prepare_cached("UPDATE items SET stub = 1 WHERE id = ?1")?;
            for id in ids {
                stmt.execute([id])?;
            }
        }
        tx.commit()?;
        Ok(())
    }

    /// Stubs still worth a try, newest first.
    pub fn stubs_to_fill(&self, limit: i64) -> Result<Vec<Item>> {
        let mut stmt = self.conn.prepare_cached(&format!(
            "SELECT {ITEM_COLS} FROM items i WHERE i.stub = 1 AND i.stub_tries < {STUB_TRIES} ORDER BY i.stub_tries, i.saved_at DESC LIMIT ?1"
        ))?;
        let rows = stmt.query_map([limit], read_item)?.collect::<rusqlite::Result<Vec<_>>>()?;
        self.attach(rows)
    }

    pub fn stub_failed(&mut self, id: &str) -> Result<()> {
        self.conn.execute("UPDATE items SET stub_tries = stub_tries + 1 WHERE id = ?1", [id])?;
        Ok(())
    }

    pub fn stub_filled(&mut self, id: &str) -> Result<()> {
        self.conn.execute("UPDATE items SET stub = 0 WHERE id = ?1", [id])?;
        Ok(())
    }

    pub fn stub_info(&self) -> Result<StubInfo> {
        Ok(self.conn.query_row(
            &format!("SELECT count(*) FILTER (WHERE stub_tries < {STUB_TRIES}), count(*) FILTER (WHERE stub_tries >= {STUB_TRIES}) FROM items WHERE stub = 1"),
            [],
            |r| Ok(StubInfo { pending: r.get(0)?, failed: r.get(1)? }),
        )?)
    }

    // --- Local files ---------------------------------------------------------

    /// Points an existing item's video at a file already in the media store
    /// (an old download of the same post). False if it has no video slot
    /// that is still empty.
    pub fn attach_video(&mut self, id: &str, file: &str) -> Result<bool> {
        let Some(mut item) = self.get(id)? else { return Ok(false) };
        let has_video = item.media.iter().any(|m| m.kind != MediaKind::Image);
        if let Some(m) = item.media.iter_mut().find(|m| m.kind != MediaKind::Image && m.video_file.is_none()) {
            m.video_file = Some(file.to_string());
        } else if !has_video {
            let mut m = Media::image(item.url.clone());
            m.kind = MediaKind::Video;
            m.video_file = Some(file.to_string());
            item.media.push(m);
        } else {
            return Ok(false);
        }
        self.set_media(id, &item.media, item.quote.as_deref())?;
        Ok(true)
    }

    /// Videos on disk without a poster image: the app draws one.
    pub fn posterless(&self, limit: i64) -> Result<Vec<(String, String)>> {
        let mut stmt = self.conn.prepare_cached(
            "SELECT i.id, json_extract(m.value, '$.video_file') FROM items i, json_each(i.media) m
              WHERE i.has_video = 1 AND json_extract(m.value, '$.video_file') IS NOT NULL
                AND json_extract(m.value, '$.file') IS NULL AND coalesce(json_extract(m.value, '$.thumb_url'), '') = ''
              ORDER BY i.saved_at DESC LIMIT ?1",
        )?;
        Ok(stmt.query_map([limit], |r| Ok((r.get(0)?, r.get(1)?)))?.collect::<rusqlite::Result<_>>()?)
    }

    /// Sets the poster of the video stored as `video_file`.
    pub fn set_poster(&mut self, id: &str, video_file: &str, poster: &str) -> Result<()> {
        let Some(mut item) = self.get(id)? else { return Ok(()) };
        for m in item.media.iter_mut().filter(|m| m.video_file.as_deref() == Some(video_file)) {
            m.file = Some(poster.to_string());
        }
        self.set_media(id, &item.media, item.quote.as_deref())
    }

    // --- Vectors ---------------------------------------------------------------

    /// Items with no vector, or one older than their last edit.
    pub fn embed_pending(&self, limit: i64) -> Result<Vec<(i64, Item)>> {
        let mut stmt = self.conn.prepare_cached(&format!(
            "SELECT {ITEM_COLS}, i.ocr FROM items i LEFT JOIN vectors v ON v.item = i.pk
              WHERE v.item IS NULL OR v.at < i.updated_at ORDER BY i.saved_at DESC LIMIT ?1"
        ))?;
        let rows = stmt
            .query_map([limit], |r| {
                let (pk, mut item) = read_item(r)?;
                item.ocr = r.get(21)?;
                Ok((pk, item))
            })?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        let pks: Vec<i64> = rows.iter().map(|(pk, _)| *pk).collect();
        let ocr: Vec<Option<String>> = rows.iter().map(|(_, i)| i.ocr.clone()).collect();
        let items = self.attach(rows)?.into_iter().zip(ocr).map(|(mut i, o)| {
            i.ocr = o;
            i
        });
        Ok(pks.into_iter().zip(items).collect())
    }

    pub fn set_vectors(&mut self, rows: &[(i64, Vec<u8>)]) -> Result<()> {
        let tx = self.write()?;
        {
            let ts = now();
            let mut stmt = tx.prepare_cached("INSERT OR REPLACE INTO vectors(item, at, vec) VALUES (?1, ?2, ?3)")?;
            for (pk, v) in rows {
                stmt.execute(params![pk, ts, v])?;
            }
        }
        tx.commit()?;
        Ok(())
    }

    pub fn clear_vectors(&mut self) -> Result<()> {
        self.conn.execute("DELETE FROM vectors", [])?;
        Ok(())
    }

    /// (items with a current vector, all items).
    pub fn vector_progress(&self) -> Result<(i64, i64)> {
        Ok(self.conn.query_row(
            "SELECT (SELECT count(*) FROM vectors v JOIN items i ON i.pk = v.item WHERE v.at >= i.updated_at), (SELECT count(*) FROM items)",
            [],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )?)
    }

    /// Vectors of the items passing the query's filters (its words are not
    /// used: that is what the vectors are for).
    pub fn vectors_for(&self, q: &Query) -> Result<Vec<(i64, Vec<u8>)>> {
        let mut wh = vec![];
        let mut args = vec![];
        item_filters(q, &mut wh, &mut args);
        let where_sql = if wh.is_empty() { String::new() } else { format!("WHERE {}", wh.join(" AND ")) };
        let mut stmt = self.conn.prepare(&format!("SELECT v.item, v.vec FROM vectors v JOIN items i ON i.pk = v.item {where_sql}"))?;
        Ok(stmt.query_map(params_from_iter(&args), |r| Ok((r.get(0)?, r.get(1)?)))?.collect::<rusqlite::Result<_>>()?)
    }

    pub fn vector_of(&self, id: &str) -> Result<Option<(i64, Vec<u8>)>> {
        Ok(self
            .conn
            .query_row("SELECT v.item, v.vec FROM vectors v JOIN items i ON i.pk = v.item WHERE i.id = ?1", [id], |r| Ok((r.get(0)?, r.get(1)?)))
            .optional()?)
    }

    /// Text-search hits (best first), with the query's filters applied.
    pub fn fts_pks(&self, q: &Query, limit: i64) -> Result<Vec<i64>> {
        let (from, where_sql, order, mut args) = Self::item_query(q, Sort::Default);
        args.push(limit.into());
        let mut stmt = self.conn.prepare(&format!("SELECT i.pk FROM {from} {where_sql} ORDER BY {order} LIMIT ?"))?;
        Ok(stmt.query_map(params_from_iter(&args), |r| r.get(0))?.collect::<rusqlite::Result<_>>()?)
    }

    /// Items matching any of `terms` (best bm25 first), with the query's
    /// filters. Each term is quoted, so nothing can inject FTS syntax.
    pub fn fts_any_pks(&self, terms: &[String], q: &Query, limit: i64) -> Result<Vec<i64>> {
        let parts: Vec<String> = terms
            .iter()
            .filter_map(|t| {
                let folded = fold(t);
                let toks = crate::text::tokens(&folded);
                match toks.as_slice() {
                    [] => None,
                    [one] if one.chars().count() < 3 => None,
                    [one] => Some(format!("\"{one}\"*")),
                    many => Some(format!("\"{}\"", many.join(" "))),
                }
            })
            .collect();
        if parts.is_empty() {
            return Ok(vec![]);
        }
        let mut wh = vec![];
        let mut args: Vec<Sql> = vec![parts.join(" OR ").into()];
        item_filters(q, &mut wh, &mut args);
        let where_sql = if wh.is_empty() { String::new() } else { format!("WHERE {}", wh.join(" AND ")) };
        args.push(limit.into());
        let mut stmt = self.conn.prepare(&format!(
            "SELECT i.pk FROM items i JOIN (SELECT rowid AS fid, rank FROM items_fts WHERE items_fts MATCH ?) f ON f.fid = i.pk {where_sql} ORDER BY f.rank LIMIT ?"
        ))?;
        Ok(stmt.query_map(params_from_iter(&args), |r| r.get(0))?.collect::<rusqlite::Result<_>>()?)
    }

    /// Items in the given order (missing ones skipped).
    pub fn items_by_pks(&self, pks: &[i64]) -> Result<Vec<Item>> {
        if pks.is_empty() {
            return Ok(vec![]);
        }
        let mut sql = format!("SELECT {ITEM_COLS} FROM items i WHERE i.pk IN (");
        append_placeholders(&mut sql, pks.len());
        sql.push(')');
        let mut stmt = self.conn.prepare(&sql)?;
        let rows = stmt.query_map(params_from_iter(pks), read_item)?.collect::<rusqlite::Result<Vec<_>>>()?;
        let order: Vec<i64> = rows.iter().map(|(pk, _)| *pk).collect();
        let mut by_pk: HashMap<i64, Item> = order.into_iter().zip(self.attach(rows)?).collect();
        Ok(pks.iter().filter_map(|pk| by_pk.remove(pk)).collect())
    }

    pub fn pk_ids(&self, pks: &[i64]) -> Result<Vec<String>> {
        let mut stmt = self.conn.prepare_cached("SELECT id FROM items WHERE pk = ?1")?;
        let mut out = vec![];
        for pk in pks {
            if let Some(id) = stmt.query_row([pk], |r| r.get::<_, String>(0)).optional()? {
                out.push(id);
            }
        }
        Ok(out)
    }

    // --- Threads ----------------------------------------------------------------

    /// Stores an X post's thread (the other posts, oldest first). Their
    /// media joins the item's own and is queued for download.
    pub fn set_thread(&mut self, id: &str, thread: Vec<Item>) -> Result<bool> {
        let Some(mut item) = self.get(id)? else { return Ok(false) };
        let mut thread = thread;
        for t in &mut thread {
            t.raw = None;
            t.thread.clear();
        }
        if thread.len() <= item.thread.len() {
            return Ok(false);
        }
        item.thread = thread;
        super::merge_thread_media(&mut item);
        let (img, vid, pending) = media_flags(&item);
        let tx = self.write()?;
        let pk = pk_of(&tx, id)?;
        tx.execute(
            "UPDATE items SET thread = ?2, media = ?3, has_image = ?4, has_video = ?5, media_pending = ?6, updated_at = ?7 WHERE pk = ?1",
            params![pk, serde_json::to_string(&item.thread)?, serde_json::to_string(&item.media)?, img, vid, pending, now()],
        )?;
        reindex_item(&tx, pk)?;
        tx.commit()?;
        Ok(true)
    }

    // --- Page copies ------------------------------------------------------------

    /// Saved web pages (not posts) with no copy yet, newest first.
    pub fn snapshot_pending(&self, limit: i64) -> Result<Vec<(String, String)>> {
        let mut stmt = self.conn.prepare_cached(
            "SELECT id, url FROM items WHERE snapshot IS NULL AND snapshot_tries < 3 AND stub = 0
               AND platform IN ('web', 'github', 'arxiv', 'hackernews') AND url LIKE 'http%'
             ORDER BY saved_at DESC LIMIT ?1",
        )?;
        Ok(stmt.query_map([limit], |r| Ok((r.get(0)?, r.get(1)?)))?.collect::<rusqlite::Result<_>>()?)
    }

    pub fn snapshot_count(&self) -> Result<(i64, i64)> {
        Ok(self.conn.query_row(
            "SELECT count(*) FILTER (WHERE snapshot IS NOT NULL), count(*) FILTER (WHERE snapshot IS NULL AND snapshot_tries < 3 AND stub = 0)
               FROM items WHERE platform IN ('web', 'github', 'arxiv', 'hackernews') AND url LIKE 'http%'",
            [],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )?)
    }

    /// Records the copy; `text` (the page as read by WebKit, scripts run)
    /// replaces the article text when it is longer.
    pub fn set_snapshot(&mut self, id: &str, file: &str, text: Option<&str>) -> Result<()> {
        let tx = self.write()?;
        let pk = pk_of(&tx, id)?;
        tx.execute("UPDATE items SET snapshot = ?2 WHERE pk = ?1", params![pk, file])?;
        if let Some(t) = text.map(str::trim).filter(|t| t.len() > 200) {
            tx.execute(
                "UPDATE items SET extra = ?2 WHERE pk = ?1 AND length(coalesce(extra, '')) < length(?2)",
                params![pk, t.chars().take(60_000).collect::<String>()],
            )?;
            reindex_item(&tx, pk)?;
        }
        tx.commit()?;
        Ok(())
    }

    pub fn snapshot_failed(&mut self, id: &str) -> Result<()> {
        self.conn.execute("UPDATE items SET snapshot_tries = snapshot_tries + 1 WHERE id = ?1", [id])?;
        Ok(())
    }

    // --- On-device summary -----------------------------------------------------

    pub fn set_ai(&mut self, id: &str, summary: Option<&str>, tags: &[String]) -> Result<()> {
        let tags = serde_json::to_string(tags)?;
        self.conn.execute("UPDATE items SET summary = ?2, ai_tags = ?3 WHERE id = ?1", params![id, summary, tags])?;
        Ok(())
    }

    // --- Duplicates -------------------------------------------------------------

    /// Groups of item pks that share a stored picture or video, or have the
    /// same text once folded (reposts). Each group has 2+ items.
    pub fn duplicate_candidates(&self) -> Result<Vec<(&'static str, Vec<i64>)>> {
        let mut groups = vec![];
        let mut stmt = self.conn.prepare(
            "SELECT group_concat(DISTINCT pk) FROM (
               SELECT i.pk AS pk, coalesce(json_extract(m.value, '$.video_file'), json_extract(m.value, '$.file')) AS f
                 FROM items i, json_each(i.media) m WHERE f IS NOT NULL)
              GROUP BY f HAVING count(DISTINCT pk) > 1",
        )?;
        for row in stmt.query_map([], |r| r.get::<_, String>(0))? {
            let pks: Vec<i64> = row?.split(',').filter_map(|p| p.parse().ok()).collect();
            if pks.len() > 1 {
                groups.push(("media", pks));
            }
        }
        let mut by_text: HashMap<String, Vec<i64>> = HashMap::new();
        let mut stmt = self.conn.prepare("SELECT pk, text FROM items WHERE length(text) >= 40")?;
        for row in stmt.query_map([], |r| Ok((r.get::<_, i64>(0)?, r.get::<_, String>(1)?)))? {
            let (pk, text) = row?;
            let key: String = fold(&text).split_whitespace().collect::<Vec<_>>().join(" ");
            by_text.entry(key).or_default().push(pk);
        }
        groups.extend(by_text.into_values().filter(|v| v.len() > 1).map(|v| ("text", v)));
        Ok(groups)
    }
}
