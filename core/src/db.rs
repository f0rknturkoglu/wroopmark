//! The library: one SQLite file with FTS5 indexes for items and links.
//!
//! Search text is folded in Rust (`text::fold`) before it reaches FTS, so
//! the FTS tables hold folded copies while `items` keeps the originals.
//! WAL + busy timeout let the app and the Chromium native host (a separate
//! process) write at the same time.

use std::collections::HashMap;
use std::path::Path;

use rusqlite::types::Value as Sql;
use rusqlite::{Connection, OptionalExtension, Row, Transaction, TransactionBehavior, params, params_from_iter};
use serde::Serialize;

use crate::media::is_name;
use crate::model::{Folder, Item, Link, Media, MediaKind, Platform};
use crate::query::{Has, Query, Sort, tag_key};
use crate::text::{fold, host_of, normalize_url, now};

pub type Result<T> = rusqlite::Result<T>;

const SCHEMA_VERSION: i64 = 9;

const SCHEMA: &str = r#"
CREATE TABLE items(
  pk            INTEGER PRIMARY KEY,
  id            TEXT NOT NULL UNIQUE,
  platform      TEXT NOT NULL,
  url           TEXT NOT NULL,
  author_handle TEXT,
  author_name   TEXT,
  author_avatar TEXT,
  title         TEXT,
  text          TEXT NOT NULL DEFAULT '',
  extra         TEXT,
  note          TEXT,
  created_at    INTEGER,
  saved_at      INTEGER NOT NULL,
  updated_at    INTEGER NOT NULL,
  media         TEXT NOT NULL DEFAULT '[]',
  quote         TEXT,
  has_image     INTEGER NOT NULL DEFAULT 0,
  has_video     INTEGER NOT NULL DEFAULT 0,
  media_pending INTEGER NOT NULL DEFAULT 0,
  raw           BLOB
);
CREATE INDEX items_saved    ON items(saved_at DESC);
CREATE INDEX items_platform ON items(platform, saved_at DESC);
CREATE INDEX items_author   ON items(author_handle COLLATE NOCASE);
CREATE INDEX items_pending  ON items(media_pending) WHERE media_pending = 1;

CREATE TABLE tags(
  id   INTEGER PRIMARY KEY,
  name TEXT NOT NULL,
  key  TEXT NOT NULL UNIQUE
);
CREATE TABLE item_tags(
  item INTEGER NOT NULL REFERENCES items(pk) ON DELETE CASCADE,
  tag  INTEGER NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
  PRIMARY KEY(item, tag)
) WITHOUT ROWID;
CREATE INDEX item_tags_tag ON item_tags(tag);

CREATE TABLE links(
  id          INTEGER PRIMARY KEY,
  url         TEXT NOT NULL UNIQUE,
  host        TEXT NOT NULL,
  title       TEXT,
  description TEXT,
  image       TEXT,
  first_seen  INTEGER NOT NULL,
  fetched_at  INTEGER,
  manual      INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX links_host ON links(host);
CREATE TABLE item_links(
  item INTEGER NOT NULL REFERENCES items(pk) ON DELETE CASCADE,
  link INTEGER NOT NULL REFERENCES links(id) ON DELETE CASCADE,
  PRIMARY KEY(item, link)
) WITHOUT ROWID;
CREATE INDEX item_links_link ON item_links(link);

CREATE VIRTUAL TABLE items_fts USING fts5(body, author, tags, tokenize = 'unicode61');
CREATE VIRTUAL TABLE links_fts USING fts5(body, tokenize = 'unicode61');
"#;

/// v1 → v2: settings, and queue existing videos for download.
const MIGRATE_2: &str = r#"
CREATE TABLE IF NOT EXISTS settings(key TEXT PRIMARY KEY, value TEXT NOT NULL);
UPDATE items SET media_pending = 1 WHERE has_video = 1;
"#;

/// v3 → v4: text recognized in images (OCR, done by the app). NULL means
/// not processed yet, '' means processed and nothing was found.
const MIGRATE_4: &str = "ALTER TABLE items ADD COLUMN ocr TEXT;";

/// v4 → v5: which local file each remote media URL was saved as, so the
/// same picture in another post is never downloaded again.
const MIGRATE_5: &str = "CREATE TABLE IF NOT EXISTS media_files(url TEXT PRIMARY KEY, file TEXT NOT NULL) WITHOUT ROWID;";

/// v5 → v6: a link whose page could not be fetched is tried again later
/// (a few times), instead of being marked done with no title.
const MIGRATE_6: &str = "ALTER TABLE links ADD COLUMN fetch_failures INTEGER NOT NULL DEFAULT 0;
                         ALTER TABLE links ADD COLUMN fetch_tried_at INTEGER;";

/// v6 → v7: items the user decided to keep in the clean-up view.
const MIGRATE_7: &str = "ALTER TABLE items ADD COLUMN reviewed_at INTEGER;";

/// v7 → v8: attempts at a video only an outside tool can fetch (TikTok).
const MIGRATE_8: &str = "ALTER TABLE items ADD COLUMN video_tries INTEGER NOT NULL DEFAULT 0;
                         ALTER TABLE items ADD COLUMN video_tried_at INTEGER;";

/// v8 → v9: folders and item-folder association.
const MIGRATE_9: &str = r#"
CREATE TABLE IF NOT EXISTS folders(
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  name       TEXT NOT NULL UNIQUE,
  created_at INTEGER NOT NULL
);
ALTER TABLE items ADD COLUMN folder_id INTEGER REFERENCES folders(id) ON DELETE SET NULL;
CREATE INDEX IF NOT EXISTS items_folder ON items(folder_id);
"#;

/// A video of the item is not on disk and its URL is a post page, not a
/// file (TikTok): only an outside downloader can get it.
const NEEDS_EXTERNAL_VIDEO: &str = "EXISTS (SELECT 1 FROM json_each(i.media) m
     WHERE json_extract(m.value, '$.kind') != 'image' AND json_extract(m.value, '$.video_file') IS NULL
       AND json_extract(m.value, '$.url') NOT LIKE '%.mp4%')";

/// Outside downloads: how many tries per video, and the wait between them.
const VIDEO_TRIES: i64 = 3;
const VIDEO_RETRY_SECS: i64 = 6 * 3600;

/// Failed link lookups: how many tries, and how long to wait between them.
const LINK_TRIES: i64 = 3;
const LINK_RETRY_SECS: i64 = 3600;

const ITEM_COLS: &str = "i.pk, i.id, i.platform, i.url, i.author_handle, i.author_name, i.author_avatar, i.title, i.text, i.created_at, i.saved_at, i.media, i.quote, i.note, i.folder_id, i.video_tries";

/// Hosts that only wrap the post's own media; never interesting as links.
const NOISE_HOSTS: [&str; 4] = ["pic.twitter.com", "pic.x.com", "t.co", "pbs.twimg.com"];

#[derive(Debug, Serialize)]
pub struct Saved {
    pub id: String,
    pub created: bool,
}

#[derive(Debug, Default, Serialize)]
pub struct SearchResult {
    pub items: Vec<Item>,
    pub total: i64,
    pub links: Vec<Link>,
}

#[derive(Debug, Serialize)]
pub struct TagCount {
    pub name: String,
    pub key: String,
    pub count: i64,
}

#[derive(Debug, Serialize)]
pub struct Stats {
    pub items: i64,
    pub by_platform: HashMap<&'static str, i64>,
    pub tags: i64,
    pub links: i64,
    pub media_pending: i64,
    /// Items with pictures not read by OCR yet.
    pub ocr_pending: i64,
    /// Videos only an outside tool can fetch, still missing; and how many
    /// of them are waiting for a (first or next) try.
    pub videos_missing: i64,
    pub videos_queued: i64,
}

pub struct Store {
    conn: Connection,
}

fn json<T: Serialize>(v: &T) -> String {
    serde_json::to_string(v).unwrap_or_else(|_| "null".into())
}

fn escape_like(s: &str) -> String {
    s.replace('\\', "\\\\").replace('%', "\\%").replace('_', "\\_")
}

fn media_flags(item: &Item) -> (bool, bool, bool) {
    let all = item.media.iter().chain(item.quote.iter().flat_map(|q| q.media.iter()));
    let (mut img, mut vid, mut pending) = (false, false, false);
    for m in all {
        match m.kind {
            MediaKind::Image => img = true,
            MediaKind::Video | MediaKind::Gif => vid = true,
        }
        pending |= m.file.is_none() && !m.local_source().is_empty();
        pending |= m.video_file.is_none() && m.downloadable_video().is_some();
    }
    (img, vid, pending)
}

/// File names only ever come from the media store. One arriving from
/// outside (an extension, `import_items`) that is not a store name — a path,
/// `..` — is dropped, so it can never be opened or deleted.
fn drop_foreign_files(media: &mut [Media]) {
    for m in media {
        m.file = m.file.take().filter(|f| is_name(f));
        m.video_file = m.video_file.take().filter(|f| is_name(f));
    }
}

/// Keeps already-downloaded files when a re-import brings the same media.
fn carry_files(new: &mut [Media], old: &[Media]) {
    for m in new.iter_mut() {
        if let Some(o) = old.iter().find(|o| o.url == m.url) {
            m.file = m.file.take().or_else(|| o.file.clone());
            m.video_file = m.video_file.take().or_else(|| o.video_file.clone());
        }
    }
}

/// Records which file each media URL was saved as.
fn remember_files(conn: &Connection, media: &[Media]) -> Result<()> {
    let mut stmt = conn.prepare_cached("INSERT OR REPLACE INTO media_files(url, file) VALUES (?1, ?2)")?;
    for m in media {
        if let Some(f) = &m.file {
            let src = m.local_source();
            if !src.is_empty() {
                stmt.execute([src, f.as_str()])?;
            }
        }
        if let Some(v) = &m.video_file {
            stmt.execute([m.url.as_str(), v.as_str()])?;
        }
    }
    Ok(())
}

/// Local pictures of an item and its quote: images and video posters.
fn image_files(item: &Item) -> Vec<String> {
    item.media.iter().chain(item.quote.iter().flat_map(|q| q.media.iter())).filter_map(|m| m.file.clone()).collect()
}

fn read_item(row: &Row) -> Result<(i64, Item)> {
    let platform: String = row.get(2)?;
    let media: String = row.get(11)?;
    let quote: Option<String> = row.get(12)?;
    Ok((
        row.get(0)?,
        Item {
            id: row.get(1)?,
            platform: Platform::parse(&platform).unwrap_or(Platform::Web),
            url: row.get(3)?,
            author_handle: row.get(4)?,
            author_name: row.get(5)?,
            author_avatar: row.get(6)?,
            title: row.get(7)?,
            text: row.get(8)?,
            created_at: row.get(9)?,
            saved_at: row.get(10)?,
            media: serde_json::from_str(&media).unwrap_or_default(),
            quote: quote.and_then(|q| serde_json::from_str(&q).ok()),
            note: row.get(13)?,
            folder_id: row.get(14)?,
            video_tries: row.get(15)?,
            ..Default::default()
        },
    ))
}

fn read_link(row: &Row) -> Result<Link> {
    Ok(Link {
        id: row.get(0)?,
        url: row.get(1)?,
        host: row.get(2)?,
        title: row.get(3)?,
        description: row.get(4)?,
        image: row.get(5)?,
        first_seen: row.get(6)?,
        manual: row.get(7)?,
        item_count: row.get(8)?,
    })
}

const LINK_COLS: &str = "l.id, l.url, l.host, l.title, l.description, l.image, l.first_seen, l.manual, \
     (SELECT count(*) FROM item_links il WHERE il.link = l.id)";

/// Rebuilds one item's FTS row from what is stored.
#[allow(clippy::type_complexity)]
fn reindex_item(conn: &Connection, pk: i64) -> Result<()> {
    let (title, text, extra, note, author_h, author_n, quote, ocr): (
        Option<String>,
        String,
        Option<String>,
        Option<String>,
        Option<String>,
        Option<String>,
        Option<String>,
        Option<String>,
    ) = conn.query_row("SELECT title, text, extra, note, author_handle, author_name, quote, ocr FROM items WHERE pk = ?1", [pk], |r| {
        Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?, r.get(5)?, r.get(6)?, r.get(7)?))
    })?;
    let quote: Option<Item> = quote.and_then(|q| serde_json::from_str(&q).ok());
    let mut body: Vec<&str> = vec![];
    body.extend(title.as_deref());
    body.push(&text);
    body.extend(note.as_deref());
    body.extend(extra.as_deref());
    body.extend(ocr.as_deref());
    if let Some(q) = &quote {
        body.extend(q.title.as_deref());
        body.push(&q.text);
    }
    let mut stmt = conn.prepare_cached("SELECT l.url FROM item_links il JOIN links l ON l.id = il.link WHERE il.item = ?1")?;
    let urls: Vec<String> = stmt.query_map([pk], |r| r.get(0))?.collect::<Result<_>>()?;
    let urls: Vec<&str> = urls.iter().map(|u| u.trim_start_matches("https://")).collect();
    body.extend(urls);

    let mut author: Vec<&str> = vec![];
    author.extend(author_h.as_deref());
    author.extend(author_n.as_deref());
    if let Some(q) = &quote {
        author.extend(q.author_handle.as_deref());
        author.extend(q.author_name.as_deref());
    }
    let mut stmt = conn.prepare_cached("SELECT t.key FROM item_tags it JOIN tags t ON t.id = it.tag WHERE it.item = ?1")?;
    let tags: Vec<String> = stmt.query_map([pk], |r| r.get::<_, String>(0))?.collect::<Result<_>>()?;

    conn.execute("DELETE FROM items_fts WHERE rowid = ?1", [pk])?;
    conn.execute(
        "INSERT INTO items_fts(rowid, body, author, tags) VALUES (?1, ?2, ?3, ?4)",
        params![pk, fold(&body.join("\n")), fold(&author.join(" ")), tags.join(" ").replace('/', " ")],
    )?;
    Ok(())
}

fn reindex_link(conn: &Connection, id: i64) -> Result<()> {
    let (url, title, desc): (String, Option<String>, Option<String>) =
        conn.query_row("SELECT url, title, description FROM links WHERE id = ?1", [id], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))?;
    let body = [Some(url.trim_start_matches("https://")), title.as_deref(), desc.as_deref()].into_iter().flatten().collect::<Vec<_>>().join("\n");
    conn.execute("DELETE FROM links_fts WHERE rowid = ?1", [id])?;
    conn.execute("INSERT INTO links_fts(rowid, body) VALUES (?1, ?2)", params![id, fold(&body)])?;
    Ok(())
}

/// Inserts (or finds) a normalized link and returns its id.
fn ensure_link(conn: &Connection, url: &str, manual: bool) -> Result<Option<i64>> {
    let Some(norm) = normalize_url(url) else { return Ok(None) };
    let host = host_of(&norm);
    if NOISE_HOSTS.contains(&host.as_str()) {
        return Ok(None);
    }
    if let Some(id) = conn.query_row("SELECT id FROM links WHERE url = ?1", [&norm], |r| r.get::<_, i64>(0)).optional()? {
        if manual {
            conn.execute("UPDATE links SET manual = 1 WHERE id = ?1", [id])?;
        }
        return Ok(Some(id));
    }
    conn.execute("INSERT INTO links(url, host, first_seen, manual) VALUES (?1, ?2, ?3, ?4)", params![norm, host, now(), manual])?;
    let id = conn.last_insert_rowid();
    reindex_link(conn, id)?;
    Ok(Some(id))
}

fn ensure_tag(conn: &Connection, name: &str) -> Result<Option<i64>> {
    let key = tag_key(name);
    if key.is_empty() {
        return Ok(None);
    }
    let display = name.trim().trim_start_matches('#').split('/').map(str::trim).filter(|p| !p.is_empty()).collect::<Vec<_>>().join("/");
    conn.execute("INSERT OR IGNORE INTO tags(name, key) VALUES (?1, ?2)", params![display, key])?;
    conn.query_row("SELECT id FROM tags WHERE key = ?1", [&key], |r| r.get(0)).map(Some)
}

fn drop_orphan_tags(conn: &Connection) -> Result<()> {
    conn.execute("DELETE FROM tags WHERE id NOT IN (SELECT tag FROM item_tags)", [])?;
    Ok(())
}

/// Links no post mentions any more (and the user did not add by hand).
fn drop_orphan_links(conn: &Connection) -> Result<()> {
    conn.execute("DELETE FROM links WHERE manual = 0 AND id NOT IN (SELECT link FROM item_links)", [])?;
    conn.execute("DELETE FROM links_fts WHERE rowid NOT IN (SELECT id FROM links)", [])?;
    Ok(())
}

/// WHERE terms (on `items i`) for everything a query says about items
/// other than their text.
fn item_filters(q: &Query, wh: &mut Vec<String>, args: &mut Vec<Sql>) {
    let marks = |n: usize| vec!["?"; n].join(",");
    for (platforms, neg) in [(&q.platforms, ""), (&q.not_platforms, "NOT ")] {
        if !platforms.is_empty() {
            wh.push(format!("i.platform {neg}IN ({})", marks(platforms.len())));
            args.extend(platforms.iter().map(|p| Sql::from(p.as_str().to_string())));
        }
    }
    for (authors, neg) in [(&q.authors, ""), (&q.not_authors, "NOT ")] {
        if !authors.is_empty() {
            wh.push(format!("lower(coalesce(i.author_handle, '')) {neg}IN ({})", marks(authors.len())));
            args.extend(authors.iter().map(|a| Sql::from(a.clone())));
        }
    }
    let tag_exists = "EXISTS (SELECT 1 FROM item_tags it JOIN tags t ON t.id = it.tag
                       WHERE it.item = i.pk AND (t.key = ? OR t.key LIKE ? ESCAPE '\\'))";
    for (tags, neg) in [(&q.tags, ""), (&q.not_tags, "NOT ")] {
        for t in tags {
            wh.push(format!("{neg}{tag_exists}"));
            args.push(t.clone().into());
            args.push(format!("{}/%", escape_like(t)).into());
        }
    }
    match q.tagged {
        Some(true) => wh.push("EXISTS (SELECT 1 FROM item_tags it WHERE it.item = i.pk)".into()),
        Some(false) => wh.push("NOT EXISTS (SELECT 1 FROM item_tags it WHERE it.item = i.pk)".into()),
        None => {}
    }
    for (has, neg) in [(&q.has, ""), (&q.not_has, "NOT ")] {
        for h in has {
            let cond = match h {
                Has::Image => "i.has_image = 1",
                Has::Video => "i.has_video = 1",
                Has::Media => "(i.has_image = 1 OR i.has_video = 1)",
                Has::Link => "EXISTS (SELECT 1 FROM item_links il2 WHERE il2.item = i.pk)",
                Has::Note => "coalesce(i.note, '') != ''",
                Has::Ocr => "coalesce(i.ocr, '') != ''",
                Has::Quote => "i.quote IS NOT NULL",
            };
            wh.push(format!("{neg}({cond})"));
        }
    }
    if let Some(t) = q.before {
        wh.push("coalesce(i.created_at, i.saved_at) < ?".into());
        args.push(t.into());
    }
    if let Some(t) = q.after {
        wh.push("coalesce(i.created_at, i.saved_at) >= ?".into());
        args.push(t.into());
    }
    match q.reviewed {
        Some(true) => wh.push("i.reviewed_at IS NOT NULL".into()),
        Some(false) => wh.push("i.reviewed_at IS NULL".into()),
        None => {}
    }
    if let Some(f) = &q.folder {
        if let Ok(id) = f.parse::<i64>() {
            wh.push("i.folder_id = ?".into());
            args.push(id.into());
        } else {
            wh.push("EXISTS (SELECT 1 FROM folders f WHERE f.id = i.folder_id AND (lower(f.name) = lower(?) OR lower(f.name) LIKE lower(?) || '/%'))".into());
            args.push(f.clone().into());
            args.push(f.clone().into());
        }
    }
    if let Some(f) = &q.not_folder {
        if let Ok(id) = f.parse::<i64>() {
            wh.push("(i.folder_id IS NULL OR i.folder_id != ?)".into());
            args.push(id.into());
        } else {
            wh.push("NOT EXISTS (SELECT 1 FROM folders f WHERE f.id = i.folder_id AND (lower(f.name) = lower(?) OR lower(f.name) LIKE lower(?) || '/%'))".into());
            args.push(f.clone().into());
            args.push(f.clone().into());
        }
    }
    match q.in_folder {
        Some(true) => wh.push("i.folder_id IS NOT NULL".into()),
        Some(false) => wh.push("i.folder_id IS NULL".into()),
        None => {}
    }
    if let Some(t) = q.saved_before {
        wh.push("i.saved_at < ?".into());
        args.push(t.into());
    }
    if let Some(t) = q.saved_after {
        wh.push("i.saved_at >= ?".into());
        args.push(t.into());
    }
}

/// Inserts or refreshes one item inside the caller's transaction.
fn upsert_in(tx: &Connection, item: &Item) -> Result<Saved> {
    let ts = now();
    let mut item = item.clone();
    drop_foreign_files(&mut item.media);
    if let Some(q) = item.quote.as_mut() {
        drop_foreign_files(&mut q.media);
    }
    let existing: Option<(i64, String, Option<String>)> =
        tx.query_row("SELECT pk, media, quote FROM items WHERE id = ?1", [&item.id], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?))).optional()?;
    if let Some((_, old, old_quote)) = &existing {
        let old: Vec<Media> = serde_json::from_str(old).unwrap_or_default();
        carry_files(&mut item.media, &old);
        let old_quote: Option<Item> = old_quote.as_deref().and_then(|q| serde_json::from_str(q).ok());
        match (item.quote.as_mut(), old_quote) {
            (Some(q), Some(o)) => carry_files(&mut q.media, &o.media),
            // The quoted post is gone from the new payload (deleted, or
            // not included); the archive keeps the copy it has.
            (None, Some(o)) => item.quote = Some(Box::new(o)),
            _ => {}
        }
    }
    let (img, vid, pending) = media_flags(&item);
    let raw = item.raw.as_ref().and_then(|r| zstd::encode_all(json(r).as_bytes(), 3).ok());
    let quote = item.quote.as_ref().map(json);
    let media = json(&item.media);

    let (pk, created) = match existing {
        Some((pk, ..)) => {
            tx.execute(
                "UPDATE items SET platform=?2, url=?3, author_handle=?4, author_name=?5, author_avatar=?6, title=?7, text=?8,
                   extra=coalesce(?9, extra), note=coalesce(?10, note), created_at=coalesce(?11, created_at), updated_at=?12,
                   media=?13, quote=?14, has_image=?15, has_video=?16, media_pending=?17, raw=coalesce(?18, raw),
                   saved_at=CASE WHEN ?19 > 0 THEN ?19 ELSE saved_at END,
                   folder_id=coalesce(?20, folder_id)
                 WHERE pk=?1",
                params![
                    pk,
                    item.platform.as_str(),
                    item.url,
                    item.author_handle,
                    item.author_name,
                    item.author_avatar,
                    item.title,
                    item.text,
                    item.extra,
                    item.note,
                    item.created_at,
                    ts,
                    media,
                    quote,
                    img,
                    vid,
                    pending,
                    raw,
                    item.saved_at,
                    item.folder_id
                ],
            )?;
            (pk, false)
        }
        None => {
            let saved = if item.saved_at > 0 { item.saved_at } else { ts };
            tx.execute(
                "INSERT INTO items(id, platform, url, author_handle, author_name, author_avatar, title, text, extra, note,
                   created_at, saved_at, updated_at, media, quote, has_image, has_video, media_pending, raw, folder_id)
                 VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,?18,?19,?20)",
                params![
                    item.id,
                    item.platform.as_str(),
                    item.url,
                    item.author_handle,
                    item.author_name,
                    item.author_avatar,
                    item.title,
                    item.text,
                    item.extra,
                    item.note,
                    item.created_at,
                    saved,
                    ts,
                    media,
                    quote,
                    img,
                    vid,
                    pending,
                    raw,
                    item.folder_id
                ],
            )?;
            (tx.last_insert_rowid(), true)
        }
    };

    // Links are rebuilt from the post on every import, so a re-parse
    // with better rules also cleans up the pool (see `upsert_all`).
    if !created {
        tx.execute("DELETE FROM item_links WHERE item = ?1", [pk])?;
    }
    let own = normalize_url(&item.url);
    let quote_links = item.quote.iter().flat_map(|q| q.links.iter());
    for url in item.links.iter().chain(quote_links) {
        if normalize_url(url) == own {
            continue;
        }
        if let Some(link) = ensure_link(tx, url, false)? {
            tx.execute("INSERT OR IGNORE INTO item_links(item, link) VALUES (?1, ?2)", [pk, link])?;
        }
    }
    for tag in &item.tags {
        if let Some(t) = ensure_tag(tx, tag)? {
            tx.execute("INSERT OR IGNORE INTO item_tags(item, tag) VALUES (?1, ?2)", [pk, t])?;
        }
    }
    reindex_item(tx, pk)?;
    Ok(Saved { id: item.id, created })
}

fn pk_of(conn: &Connection, id: &str) -> Result<i64> {
    conn.query_row("SELECT pk FROM items WHERE id = ?1", [id], |r| r.get(0))
}

impl Store {
    pub fn open(path: &Path) -> Result<Self> {
        Self::init(Connection::open(path)?)
    }

    pub fn open_in_memory() -> Result<Self> {
        Self::init(Connection::open_in_memory()?)
    }

    fn init(conn: Connection) -> Result<Self> {
        conn.execute_batch(
            "PRAGMA journal_mode = WAL;
             PRAGMA synchronous = NORMAL;
             PRAGMA foreign_keys = ON;
             PRAGMA busy_timeout = 5000;",
        )?;
        let version: i64 = conn.query_row("PRAGMA user_version", [], |r| r.get(0))?;
        if version == 0 {
            conn.execute_batch(&format!(
                "BEGIN; {SCHEMA} {MIGRATE_2} {MIGRATE_4} {MIGRATE_5} {MIGRATE_6} {MIGRATE_7} {MIGRATE_8} {MIGRATE_9} PRAGMA user_version = {SCHEMA_VERSION}; COMMIT;"
            ))?;
        } else if version == 1 {
            conn.execute_batch(&format!("BEGIN; {MIGRATE_2} PRAGMA user_version = 2; COMMIT;"))?;
        }
        let mut store = Self { conn };
        if (1..3).contains(&version) {
            store.reapply_bookmark_times()?;
            store.conn.execute_batch("PRAGMA user_version = 3;")?;
        }
        if (1..4).contains(&version) {
            store.conn.execute_batch(&format!("BEGIN; {MIGRATE_4} PRAGMA user_version = 4; COMMIT;"))?;
        }
        if (1..5).contains(&version) {
            store.conn.execute_batch(MIGRATE_5)?;
            store.backfill_media_files()?;
            store.conn.execute_batch("PRAGMA user_version = 5;")?;
        }
        if (1..6).contains(&version) {
            store.conn.execute_batch(&format!("BEGIN; {MIGRATE_6} PRAGMA user_version = 6; COMMIT;"))?;
        }
        if (1..7).contains(&version) {
            store.conn.execute_batch(&format!("BEGIN; {MIGRATE_7} PRAGMA user_version = 7; COMMIT;"))?;
        }
        if (1..8).contains(&version) {
            store.conn.execute_batch(&format!("BEGIN; {MIGRATE_8} PRAGMA user_version = 8; COMMIT;"))?;
        }
        if (1..9).contains(&version) {
            store.conn.execute_batch(&format!("BEGIN; {MIGRATE_9} PRAGMA user_version = 9; COMMIT;"))?;
        }
        Ok(store)
    }

    /// Write transactions take the write lock up front. A deferred one that
    /// reads first and then writes fails at once with "database is locked"
    /// (no busy wait) when the other process committed in between.
    fn write(&mut self) -> Result<Transaction<'_>> {
        self.conn.transaction_with_behavior(TransactionBehavior::Immediate)
    }

    /// Bumps whenever another connection (the browser extension's host)
    /// commits; the app polls it to refresh live.
    pub fn data_version(&self) -> Result<i64> {
        self.conn.query_row("PRAGMA data_version", [], |r| r.get(0))
    }

    /// v2 → v3: X bookmarks saved before the bookmark-time rule worked get
    /// their real save time from the `sortIndex` kept in their raw payload.
    fn reapply_bookmark_times(&mut self) -> Result<usize> {
        let tx = self.write()?;
        let rows: Vec<(i64, String, Option<i64>, Vec<u8>)> = tx
            .prepare("SELECT pk, id, created_at, raw FROM items WHERE platform = 'x' AND raw IS NOT NULL")?
            .query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)))?
            .collect::<Result<_>>()?;
        let mut n = 0;
        for (pk, id, created_at, blob) in rows {
            let raw: Option<serde_json::Value> = zstd::decode_all(&blob[..]).ok().and_then(|b| serde_json::from_slice(&b).ok());
            let Some(sort) = raw.as_ref().and_then(|r| r.get("__sortIndex")).and_then(|v| v.as_str()) else { continue };
            let probe = Item { id, created_at, ..Default::default() };
            if let Some(t) = crate::x::bookmark_time(sort, &probe) {
                n += tx.execute("UPDATE items SET saved_at = ?2 WHERE pk = ?1", [pk, t])?;
            }
        }
        tx.commit()?;
        Ok(n)
    }

    /// The local file a media URL was already saved as, if any.
    pub fn known_file(&self, url: &str) -> Result<Option<String>> {
        self.conn.query_row("SELECT file FROM media_files WHERE url = ?1", [url], |r| r.get(0)).optional()
    }

    fn backfill_media_files(&mut self) -> Result<()> {
        let tx = self.write()?;
        let rows: Vec<(String, Option<String>)> =
            tx.prepare("SELECT media, quote FROM items")?.query_map([], |r| Ok((r.get(0)?, r.get(1)?)))?.collect::<Result<_>>()?;
        for (media, quote) in rows {
            let mut all: Vec<Media> = serde_json::from_str(&media).unwrap_or_default();
            if let Some(q) = quote.and_then(|q| serde_json::from_str::<Item>(&q).ok()) {
                all.extend(q.media);
            }
            remember_files(&tx, &all)?;
        }
        tx.commit()
    }

    pub fn setting(&self, key: &str) -> Result<Option<String>> {
        self.conn.query_row("SELECT value FROM settings WHERE key = ?1", [key], |r| r.get(0)).optional()
    }

    pub fn set_setting(&mut self, key: &str, value: &str) -> Result<()> {
        self.conn.execute("INSERT INTO settings(key, value) VALUES (?1, ?2) ON CONFLICT(key) DO UPDATE SET value = ?2", [key, value])?;
        Ok(())
    }

    /// Puts every item with a video back in the download queue.
    pub fn queue_videos(&mut self) -> Result<usize> {
        self.conn.execute("UPDATE items SET media_pending = 1 WHERE has_video = 1", [])
    }

    pub fn checkpoint(&self) {
        let _ = self.conn.execute_batch("PRAGMA wal_checkpoint(TRUNCATE);");
    }

    /// Inserts or refreshes an item. A refresh keeps the note, downloaded
    /// media files, the quoted post if the new payload lacks it, and existing
    /// tags (new tags are added). The save time is kept too, unless the new
    /// payload carries one (X bookmarks know when they were bookmarked).
    pub fn upsert(&mut self, item: &Item) -> Result<Saved> {
        Ok(self.upsert_all(std::slice::from_ref(item))?.remove(0))
    }

    /// Saves a batch (one page of an import) in a single transaction.
    pub fn upsert_all(&mut self, items: &[Item]) -> Result<Vec<Saved>> {
        let tx = self.write()?;
        let saved = items.iter().map(|item| upsert_in(&tx, item)).collect::<Result<Vec<_>>>()?;
        if saved.iter().any(|s| !s.created) {
            drop_orphan_links(&tx)?;
        }
        tx.commit()?;
        Ok(saved)
    }

    fn attach(&self, rows: Vec<(i64, Item)>) -> Result<Vec<Item>> {
        if rows.is_empty() {
            return Ok(vec![]);
        }
        let pks: Vec<i64> = rows.iter().map(|(pk, _)| *pk).collect();
        let marks = vec!["?"; pks.len()].join(",");
        let mut tags: HashMap<i64, Vec<String>> = HashMap::new();
        let mut stmt = self
            .conn
            .prepare(&format!("SELECT it.item, t.name FROM item_tags it JOIN tags t ON t.id = it.tag WHERE it.item IN ({marks}) ORDER BY t.key"))?;
        for r in stmt.query_map(params_from_iter(&pks), |r| Ok((r.get::<_, i64>(0)?, r.get::<_, String>(1)?)))? {
            let (pk, name) = r?;
            tags.entry(pk).or_default().push(name);
        }
        let mut links: HashMap<i64, Vec<String>> = HashMap::new();
        let mut stmt =
            self.conn.prepare(&format!("SELECT il.item, l.url FROM item_links il JOIN links l ON l.id = il.link WHERE il.item IN ({marks})"))?;
        for r in stmt.query_map(params_from_iter(&pks), |r| Ok((r.get::<_, i64>(0)?, r.get::<_, String>(1)?)))? {
            let (pk, url) = r?;
            links.entry(pk).or_default().push(url);
        }
        Ok(rows
            .into_iter()
            .map(|(pk, mut item)| {
                item.tags = tags.remove(&pk).unwrap_or_default();
                item.links = links.remove(&pk).unwrap_or_default();
                item
            })
            .collect())
    }

    /// Full item, including search-only `extra` text (but not `raw`).
    pub fn get(&self, id: &str) -> Result<Option<Item>> {
        let row = self
            .conn
            .query_row(&format!("SELECT {ITEM_COLS}, i.extra, i.ocr FROM items i WHERE i.id = ?1"), [id], |r| {
                let (pk, mut item) = read_item(r)?;
                item.extra = r.get(16)?;
                item.ocr = r.get(17)?;
                Ok((pk, item))
            })
            .optional()?;
        Ok(row.map(|r| self.attach(vec![r])).transpose()?.and_then(|mut v| v.pop()))
    }

    /// The original payload an item was parsed from.
    pub fn raw(&self, id: &str) -> Result<Option<serde_json::Value>> {
        let blob: Option<Option<Vec<u8>>> = self.conn.query_row("SELECT raw FROM items WHERE id = ?1", [id], |r| r.get(0)).optional()?;
        Ok(blob.flatten().and_then(|b| zstd::decode_all(&b[..]).ok()).and_then(|b| serde_json::from_slice(&b).ok()))
    }

    pub fn search(&self, q: &Query, sort: Sort, limit: i64, offset: i64) -> Result<SearchResult> {
        let mut from = "items i".to_string();
        let mut order = "i.saved_at DESC, i.pk DESC".to_string();
        let mut wh: Vec<String> = vec![];
        let mut args: Vec<Sql> = vec![];

        if let Some(pos) = q.fts_positive() {
            let m = match q.fts_negative() {
                Some(neg) => format!("({pos}) NOT ({neg})"),
                None => pos,
            };
            from = "items i JOIN (SELECT rowid AS fid, rank FROM items_fts WHERE items_fts MATCH ?) f ON f.fid = i.pk".into();
            args.push(m.into());
            order = "f.rank, i.saved_at DESC".into();
        } else if let Some(neg) = q.fts_negative() {
            wh.push("i.pk NOT IN (SELECT rowid FROM items_fts WHERE items_fts MATCH ?)".into());
            args.push(neg.into());
        }
        item_filters(q, &mut wh, &mut args);
        if let Some(o) = sort.sql() {
            order = o;
        }
        let where_sql = if wh.is_empty() { String::new() } else { format!("WHERE {}", wh.join(" AND ")) };

        let total: i64 = self.conn.query_row(&format!("SELECT count(*) FROM {from} {where_sql}"), params_from_iter(&args), |r| r.get(0))?;
        let mut page_args = args.clone();
        page_args.push(limit.into());
        page_args.push(offset.into());
        let mut stmt = self.conn.prepare(&format!("SELECT {ITEM_COLS} FROM {from} {where_sql} ORDER BY {order} LIMIT ? OFFSET ?"))?;
        let rows = stmt.query_map(params_from_iter(&page_args), read_item)?.collect::<Result<Vec<_>>>()?;
        let items = self.attach(rows)?;

        let links = if offset == 0 && q.has_text() { self.search_links(q, 20, 0)? } else { vec![] };
        Ok(SearchResult { items, total, links })
    }

    /// Links matching the query's text. Item filters (tags, author, dates…)
    /// keep the links that appear in at least one matching item.
    fn search_links(&self, q: &Query, limit: i64, offset: i64) -> Result<Vec<Link>> {
        let mut from = "links l".to_string();
        let mut order = "l.first_seen DESC, l.id DESC";
        let mut wh: Vec<String> = vec![];
        let mut args: Vec<Sql> = vec![];
        if let Some(pos) = q.fts_positive() {
            let m = match q.fts_negative() {
                Some(neg) => format!("({pos}) NOT ({neg})"),
                None => pos,
            };
            from = "links l JOIN (SELECT rowid AS fid, rank FROM links_fts WHERE links_fts MATCH ?) f ON f.fid = l.id".into();
            args.push(m.into());
            order = "f.rank";
        } else if let Some(neg) = q.fts_negative() {
            wh.push("l.id NOT IN (SELECT rowid FROM links_fts WHERE links_fts MATCH ?)".into());
            args.push(neg.into());
        }
        if q.filters_items() {
            let mut inner = vec!["il.link = l.id".to_string()];
            item_filters(q, &mut inner, &mut args);
            wh.push(format!("EXISTS (SELECT 1 FROM item_links il JOIN items i ON i.pk = il.item WHERE {})", inner.join(" AND ")));
        }
        let where_sql = if wh.is_empty() { String::new() } else { format!("WHERE {}", wh.join(" AND ")) };
        args.push(limit.into());
        args.push(offset.into());
        let mut stmt = self.conn.prepare(&format!("SELECT {LINK_COLS} FROM {from} {where_sql} ORDER BY {order} LIMIT ? OFFSET ?"))?;
        stmt.query_map(params_from_iter(&args), read_link)?.collect()
    }

    /// The link pool, newest first, optionally filtered by free text.
    pub fn links(&self, text: &str, limit: i64, offset: i64) -> Result<Vec<Link>> {
        self.search_links(&Query::parse(text), limit, offset)
    }

    pub fn link_items(&self, link_id: i64) -> Result<Vec<Item>> {
        let mut stmt = self
            .conn
            .prepare(&format!("SELECT {ITEM_COLS} FROM items i JOIN item_links il ON il.item = i.pk WHERE il.link = ?1 ORDER BY i.saved_at DESC"))?;
        let rows = stmt.query_map([link_id], read_item)?.collect::<Result<Vec<_>>>()?;
        self.attach(rows)
    }

    pub fn add_link(&mut self, url: &str) -> Result<Option<Link>> {
        let Some(id) = ensure_link(&self.conn, url, true)? else { return Ok(None) };
        self.conn.query_row(&format!("SELECT {LINK_COLS} FROM links l WHERE l.id = ?1"), [id], read_link).optional()
    }

    pub fn delete_link(&mut self, id: i64) -> Result<()> {
        let tx = self.write()?;
        let items: Vec<i64> = tx.prepare("SELECT item FROM item_links WHERE link = ?1")?.query_map([id], |r| r.get(0))?.collect::<Result<_>>()?;
        tx.execute("DELETE FROM links WHERE id = ?1", [id])?;
        tx.execute("DELETE FROM links_fts WHERE rowid = ?1", [id])?;
        for pk in items {
            reindex_item(&tx, pk)?;
        }
        tx.commit()
    }

    /// Links without page details yet. One that failed is left alone for an
    /// hour, and given up on after a few tries.
    pub fn links_to_enrich(&self, limit: i64) -> Result<Vec<(i64, String)>> {
        let mut stmt = self.conn.prepare_cached(
            "SELECT id, url FROM links WHERE fetched_at IS NULL AND fetch_failures < ?2 AND coalesce(fetch_tried_at, 0) < ?3
             ORDER BY manual DESC, id DESC LIMIT ?1",
        )?;
        stmt.query_map(params![limit, LINK_TRIES, now() - LINK_RETRY_SECS], |r| Ok((r.get(0)?, r.get(1)?)))?.collect()
    }

    /// The page could not be fetched; it stays in line for another try.
    pub fn link_fetch_failed(&mut self, id: i64) -> Result<()> {
        self.conn.execute("UPDATE links SET fetch_failures = fetch_failures + 1, fetch_tried_at = ?2 WHERE id = ?1", params![id, now()])?;
        Ok(())
    }

    pub fn set_link_meta(&mut self, id: i64, title: Option<&str>, description: Option<&str>, image: Option<&str>) -> Result<()> {
        self.conn.execute(
            "UPDATE links SET title = coalesce(?2, title), description = coalesce(?3, description), image = coalesce(?4, image), fetched_at = ?5 WHERE id = ?1",
            params![id, title, description, image, now()],
        )?;
        reindex_link(&self.conn, id)
    }

    /// Replaces an item's tags.
    pub fn set_tags(&mut self, id: &str, tags: &[String]) -> Result<()> {
        let tx = self.write()?;
        let pk = pk_of(&tx, id)?;
        tx.execute("DELETE FROM item_tags WHERE item = ?1", [pk])?;
        for t in tags {
            if let Some(tag) = ensure_tag(&tx, t)? {
                tx.execute("INSERT OR IGNORE INTO item_tags(item, tag) VALUES (?1, ?2)", [pk, tag])?;
            }
        }
        drop_orphan_tags(&tx)?;
        reindex_item(&tx, pk)?;
        tx.commit()
    }

    /// Adds and removes tags on many items at once (multi-select in the UI).
    pub fn edit_tags(&mut self, ids: &[String], add: &[String], remove: &[String]) -> Result<()> {
        let tx = self.write()?;
        let remove: Vec<String> = remove.iter().map(|t| tag_key(t)).collect();
        for id in ids {
            let pk = pk_of(&tx, id)?;
            for t in add {
                if let Some(tag) = ensure_tag(&tx, t)? {
                    tx.execute("INSERT OR IGNORE INTO item_tags(item, tag) VALUES (?1, ?2)", [pk, tag])?;
                }
            }
            for key in &remove {
                tx.execute("DELETE FROM item_tags WHERE item = ?1 AND tag = (SELECT id FROM tags WHERE key = ?2)", params![pk, key])?;
            }
            reindex_item(&tx, pk)?;
        }
        drop_orphan_tags(&tx)?;
        tx.commit()
    }

    /// Renames a tag and everything under it: `dev` → `kod` turns `dev/rust`
    /// into `kod/rust`. Merges into existing tags when names collide.
    pub fn rename_tag(&mut self, from: &str, to: &str) -> Result<usize> {
        let (from_key, to_name) = (tag_key(from), to.trim().trim_start_matches('#').to_string());
        if from_key.is_empty() || tag_key(&to_name).is_empty() {
            return Ok(0);
        }
        let tx = self.write()?;
        let affected: Vec<(i64, String)> = tx
            .prepare("SELECT id, name FROM tags WHERE key = ?1 OR key LIKE ?2 ESCAPE '\\'")?
            .query_map(params![from_key, format!("{}/%", escape_like(&from_key))], |r| Ok((r.get(0)?, r.get(1)?)))?
            .collect::<Result<_>>()?;
        let mut items: Vec<i64> = vec![];
        for (old_id, old_name) in &affected {
            let suffix = old_name.splitn(from_key.split('/').count() + 1, '/').nth(from_key.split('/').count());
            let new_name = match suffix {
                Some(s) => format!("{to_name}/{s}"),
                None => to_name.clone(),
            };
            let Some(new_id) = ensure_tag(&tx, &new_name)? else {
                continue;
            };
            if new_id == *old_id {
                tx.execute("UPDATE tags SET name = ?2 WHERE id = ?1", params![old_id, new_name])?;
                continue;
            }
            let pks: Vec<i64> = tx.prepare("SELECT item FROM item_tags WHERE tag = ?1")?.query_map([old_id], |r| r.get(0))?.collect::<Result<_>>()?;
            for pk in &pks {
                tx.execute("INSERT OR IGNORE INTO item_tags(item, tag) VALUES (?1, ?2)", [pk, &new_id])?;
            }
            tx.execute("DELETE FROM tags WHERE id = ?1", [old_id])?;
            items.extend(pks);
        }
        items.sort_unstable();
        items.dedup();
        for pk in &items {
            reindex_item(&tx, *pk)?;
        }
        tx.commit()?;
        Ok(affected.len())
    }

    pub fn tags(&self) -> Result<Vec<TagCount>> {
        let mut stmt = self.conn.prepare_cached(
            "SELECT t.name, t.key, count(it.item) FROM tags t LEFT JOIN item_tags it ON it.tag = t.id GROUP BY t.id ORDER BY t.key",
        )?;
        stmt.query_map([], |r| Ok(TagCount { name: r.get(0)?, key: r.get(1)?, count: r.get(2)? }))?.collect()
    }

    pub fn folders(&self) -> Result<Vec<Folder>> {
        let mut stmt = self.conn.prepare_cached(
            "SELECT f.id, f.name, f.created_at, count(i.pk)
             FROM folders f
             LEFT JOIN items i ON i.folder_id = f.id
             GROUP BY f.id
             ORDER BY lower(f.name) ASC",
        )?;
        stmt.query_map([], |r| {
            Ok(Folder {
                id: r.get(0)?,
                name: r.get(1)?,
                created_at: r.get(2)?,
                count: r.get(3)?,
            })
        })?
        .collect()
    }

    pub fn add_folder(&mut self, name: &str) -> Result<Folder> {
        let clean = name.trim();
        if clean.is_empty() {
            return Err(rusqlite::Error::InvalidParameterName("klasör adı boş olamaz".into()));
        }
        let now = now();
        self.conn.execute("INSERT INTO folders(name, created_at) VALUES (?1, ?2)", params![clean, now])?;
        let id = self.conn.last_insert_rowid();
        Ok(Folder {
            id,
            name: clean.to_string(),
            created_at: now,
            count: 0,
        })
    }

    pub fn rename_folder(&mut self, id: i64, name: &str) -> Result<()> {
        let clean = name.trim();
        if clean.is_empty() {
            return Err(rusqlite::Error::InvalidParameterName("klasör adı boş olamaz".into()));
        }
        self.conn.execute("UPDATE folders SET name = ?2 WHERE id = ?1", params![id, clean])?;
        Ok(())
    }

    pub fn delete_folder(&mut self, id: i64) -> Result<()> {
        let tx = self.write()?;
        tx.execute("UPDATE items SET folder_id = NULL WHERE folder_id = ?1", [id])?;
        tx.execute("DELETE FROM folders WHERE id = ?1", [id])?;
        tx.commit()
    }

    pub fn move_to_folder(&mut self, id: &str, folder_id: Option<i64>) -> Result<()> {
        let pk = pk_of(&self.conn, id)?;
        self.conn.execute("UPDATE items SET folder_id = ?2, updated_at = ?3 WHERE pk = ?1", params![pk, folder_id, now()])?;
        Ok(())
    }

    pub fn move_items_to_folder(&mut self, ids: &[String], folder_id: Option<i64>) -> Result<()> {
        let tx = self.write()?;
        let now = now();
        for id in ids {
            if let Ok(pk) = pk_of(&tx, id) {
                tx.execute("UPDATE items SET folder_id = ?2, updated_at = ?3 WHERE pk = ?1", params![pk, folder_id, now])?;
            }
        }
        tx.commit()
    }

    pub fn completed_video_downloads(&self, limit: i64) -> Result<Vec<Item>> {
        let mut stmt = self.conn.prepare_cached(&format!(
            "SELECT {ITEM_COLS} FROM items i WHERE i.has_video = 1
               AND EXISTS (SELECT 1 FROM json_each(i.media) m WHERE json_extract(m.value, '$.video_file') IS NOT NULL)
             ORDER BY i.saved_at DESC LIMIT ?1"
        ))?;
        let rows = stmt.query_map([limit], read_item)?.collect::<Result<Vec<_>>>()?;
        self.attach(rows)
    }

    pub fn failed_video_downloads(&self, limit: i64) -> Result<Vec<Item>> {
        let mut stmt = self.conn.prepare_cached(&format!(
            "SELECT {ITEM_COLS} FROM items i WHERE i.has_video = 1 AND i.video_tries > 0
               AND {NEEDS_EXTERNAL_VIDEO}
             ORDER BY coalesce(i.video_tried_at, 0) DESC LIMIT ?1"
        ))?;
        let rows = stmt.query_map([limit], read_item)?.collect::<Result<Vec<_>>>()?;
        self.attach(rows)
    }

    pub fn retry_video_download(&mut self, id: &str) -> Result<()> {
        self.conn.execute(
            "UPDATE items SET video_tries = 0, video_tried_at = 0, media_pending = 1 WHERE id = ?1",
            [id],
        )?;
        Ok(())
    }

    pub fn retry_all_video_downloads(&mut self) -> Result<usize> {
        self.conn.execute(
            "UPDATE items SET video_tries = 0, video_tried_at = 0, media_pending = 1 WHERE has_video = 1 AND video_tries > 0",
            [],
        )
    }

    pub fn set_note(&mut self, id: &str, note: Option<&str>) -> Result<()> {
        let note = note.map(str::trim).filter(|n| !n.is_empty());
        let pk = pk_of(&self.conn, id)?;
        self.conn.execute("UPDATE items SET note = ?2, updated_at = ?3 WHERE pk = ?1", params![pk, note, now()])?;
        reindex_item(&self.conn, pk)
    }

    /// Search-only text from outside the core, e.g. OCR done by the app.
    pub fn set_extra(&mut self, id: &str, extra: &str) -> Result<()> {
        let pk = pk_of(&self.conn, id)?;
        self.conn.execute("UPDATE items SET extra = ?2 WHERE pk = ?1", params![pk, extra])?;
        reindex_item(&self.conn, pk)
    }

    /// Deletes an item. Returns media files no other item references, for
    /// the caller to remove from disk.
    pub fn delete(&mut self, id: &str) -> Result<Vec<String>> {
        let tx = self.write()?;
        let Some((pk, media, quote)) = tx
            .query_row("SELECT pk, media, quote FROM items WHERE id = ?1", [id], |r| {
                Ok((r.get::<_, i64>(0)?, r.get::<_, String>(1)?, r.get::<_, Option<String>>(2)?))
            })
            .optional()?
        else {
            return Ok(vec![]);
        };
        let mut all: Vec<Media> = serde_json::from_str(&media).unwrap_or_default();
        if let Some(q) = quote.and_then(|q| serde_json::from_str::<Item>(&q).ok()) {
            all.extend(q.media);
        }
        let files: Vec<String> = all.into_iter().flat_map(|m| [m.file, m.video_file]).flatten().collect();
        tx.execute("DELETE FROM items WHERE pk = ?1", [pk])?;
        tx.execute("DELETE FROM items_fts WHERE rowid = ?1", [pk])?;
        drop_orphan_tags(&tx)?;
        drop_orphan_links(&tx)?;
        let mut orphans = vec![];
        for f in files {
            let used: bool = tx.query_row(
                "SELECT EXISTS(SELECT 1 FROM items WHERE media LIKE ?1 ESCAPE '\\' OR quote LIKE ?1 ESCAPE '\\')",
                [format!("%{}%", escape_like(&f))],
                |r| r.get(0),
            )?;
            if !used {
                tx.execute("DELETE FROM media_files WHERE file = ?1", [&f])?;
                orphans.push(f);
            }
        }
        tx.commit()?;
        Ok(orphans)
    }

    /// Items with media not yet on disk.
    pub fn pending_media(&self, limit: i64) -> Result<Vec<Item>> {
        let mut stmt =
            self.conn.prepare_cached(&format!("SELECT {ITEM_COLS} FROM items i WHERE i.media_pending = 1 ORDER BY i.saved_at DESC LIMIT ?1"))?;
        stmt.query_map([limit], read_item)?.map(|r| r.map(|(_, item)| item)).collect()
    }

    /// Stores the media list after a download pass; the item is no longer
    /// pending even if some files failed (they are retried only on demand).
    pub fn set_media(&mut self, id: &str, media: &[Media], quote: Option<&Item>) -> Result<()> {
        let probe = Item { media: media.to_vec(), quote: quote.cloned().map(Box::new), ..Default::default() };
        let (img, vid, _) = media_flags(&probe);
        // New pictures on disk mean the OCR text (if any) is incomplete.
        let before = self.get(id)?.map(|i| image_files(&i)).unwrap_or_default();
        let reset_ocr = image_files(&probe) != before;
        remember_files(&self.conn, &probe.media)?;
        if let Some(q) = quote {
            remember_files(&self.conn, &q.media)?;
        }
        self.conn.execute(
            "UPDATE items SET media = ?2, quote = coalesce(?3, quote), has_image = ?4, has_video = ?5, media_pending = 0,
               ocr = CASE WHEN ?6 THEN NULL ELSE ocr END
             WHERE id = ?1",
            params![id, json(&media), quote.map(json), img, vid, reset_ocr],
        )?;
        Ok(())
    }

    /// Items whose pictures are on disk but not yet read by OCR, with the
    /// files to read. Items with nothing to read are marked done on the way.
    pub fn ocr_pending(&mut self, limit: i64) -> Result<Vec<(String, Vec<String>)>> {
        let mut out = vec![];
        let mut empty = vec![];
        {
            let mut stmt = self.conn.prepare_cached(&format!(
                "SELECT {ITEM_COLS} FROM items i WHERE i.ocr IS NULL AND i.media_pending = 0 ORDER BY i.saved_at DESC LIMIT ?1"
            ))?;
            for row in stmt.query_map([limit], read_item)? {
                let (_, item) = row?;
                let files = image_files(&item);
                if files.is_empty() { empty.push(item.id) } else { out.push((item.id, files)) }
            }
        }
        for id in empty {
            self.conn.execute("UPDATE items SET ocr = '' WHERE id = ?1", [id])?;
        }
        Ok(out)
    }

    /// Items whose video only an outside tool can fetch, not tried too
    /// often or too recently; newest saved first.
    pub fn external_video_queue(&self, limit: i64) -> Result<Vec<Item>> {
        let mut stmt = self.conn.prepare_cached(&format!(
            "SELECT {ITEM_COLS} FROM items i WHERE i.has_video = 1 AND i.platform != 'youtube' AND {NEEDS_EXTERNAL_VIDEO}
               AND i.video_tries < ?2 AND coalesce(i.video_tried_at, 0) < ?3
             ORDER BY i.saved_at DESC LIMIT ?1"
        ))?;
        stmt.query_map(params![limit, VIDEO_TRIES, now() - VIDEO_RETRY_SECS], read_item)?.map(|r| r.map(|(_, item)| item)).collect()
    }

    /// An outside download failed; the item waits before the next try.
    pub fn video_failed(&mut self, id: &str) -> Result<()> {
        self.conn.execute("UPDATE items SET video_tries = video_tries + 1, video_tried_at = ?2 WHERE id = ?1", params![id, now()])?;
        Ok(())
    }

    /// Marks items as kept (or not) in the clean-up view; kept items stay
    /// out of it until reset.
    pub fn set_reviewed(&mut self, ids: &[String], reviewed: bool) -> Result<usize> {
        let tx = self.write()?;
        let mut n = 0;
        for id in ids {
            n += tx.execute("UPDATE items SET reviewed_at = CASE WHEN ?2 THEN ?3 ELSE NULL END WHERE id = ?1", params![id, reviewed, now()])?;
        }
        tx.commit()?;
        Ok(n)
    }

    /// Puts every kept item back in the clean-up view.
    pub fn reset_reviewed(&mut self) -> Result<usize> {
        self.conn.execute("UPDATE items SET reviewed_at = NULL WHERE reviewed_at IS NOT NULL", [])
    }

    /// Stores recognized text ('' when there was none) and reindexes.
    pub fn set_ocr(&mut self, id: &str, text: &str) -> Result<()> {
        let pk = pk_of(&self.conn, id)?;
        self.conn.execute("UPDATE items SET ocr = ?2 WHERE pk = ?1", params![pk, text.trim()])?;
        reindex_item(&self.conn, pk)
    }

    /// Puts back in the download queue the items with something still not
    /// on disk (a failed picture, poster or video).
    pub fn retry_media(&mut self) -> Result<usize> {
        let tx = self.write()?;
        let rows: Vec<(i64, String, Option<String>)> = tx
            .prepare("SELECT pk, media, quote FROM items WHERE media_pending = 0")?
            .query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))?
            .collect::<Result<_>>()?;
        let mut n = 0;
        for (pk, media, quote) in rows {
            let probe = Item {
                media: serde_json::from_str(&media).unwrap_or_default(),
                quote: quote.and_then(|q| serde_json::from_str(&q).ok()).map(Box::new),
                ..Default::default()
            };
            if media_flags(&probe).2 {
                n += tx.execute("UPDATE items SET media_pending = 1 WHERE pk = ?1", [pk])?;
            }
        }
        tx.commit()?;
        Ok(n)
    }

    pub fn stats(&self) -> Result<Stats> {
        let one = |sql: &str| self.conn.query_row(sql, [], |r| r.get::<_, i64>(0));
        let mut by_platform = HashMap::new();
        for p in Platform::ALL {
            let n: i64 = self.conn.query_row("SELECT count(*) FROM items WHERE platform = ?1", [p.as_str()], |r| r.get(0))?;
            by_platform.insert(p.as_str(), n);
        }
        Ok(Stats {
            items: one("SELECT count(*) FROM items")?,
            by_platform,
            tags: one("SELECT count(*) FROM tags")?,
            links: one("SELECT count(*) FROM links")?,
            media_pending: one("SELECT count(*) FROM items WHERE media_pending = 1")?,
            ocr_pending: one("SELECT count(*) FROM items WHERE ocr IS NULL AND media_pending = 0 AND (has_image = 1 OR has_video = 1)")?,
            videos_missing: one(&format!("SELECT count(*) FROM items i WHERE i.has_video = 1 AND {NEEDS_EXTERNAL_VIDEO}"))?,
            videos_queued: self.conn.query_row(
                &format!(
                    "SELECT count(*) FROM items i WHERE i.has_video = 1 AND i.platform != 'youtube' AND {NEEDS_EXTERNAL_VIDEO}
                       AND i.video_tries < ?1 AND coalesce(i.video_tried_at, 0) < ?2"
                ),
                params![VIDEO_TRIES, now() - VIDEO_RETRY_SECS],
                |r| r.get(0),
            )?,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn post(id: &str, text: &str) -> Item {
        Item {
            id: format!("x:{id}"),
            platform: Platform::X,
            url: format!("https://x.com/u/status/{id}"),
            author_handle: Some("Jack".into()),
            text: text.into(),
            ..Default::default()
        }
    }

    #[test]
    fn search_roundtrip() {
        let mut s = Store::open_in_memory().unwrap();
        let mut a = post("1", "İSTANBUL'da Rust buluşması https://t.co/abc");
        a.links = vec!["https://github.com/rust-lang/rust?utm_source=x".into()];
        a.media = vec![Media::image("https://pbs.twimg.com/media/a.jpg")];
        a.tags = vec!["Dev/Rust".into()];
        assert!(s.upsert(&a).unwrap().created);
        s.upsert(&post("2", "swift ve ıspanak")).unwrap();

        let find = |s: &Store, q: &str| s.search(&Query::parse(q), Sort::Default, 50, 0).unwrap();
        assert_eq!(find(&s, "istanbul").total, 1);
        assert_eq!(find(&s, "ISPANAK").total, 1);
        assert_eq!(find(&s, "buluş").total, 1); // prefix
        assert_eq!(find(&s, "tag:dev").total, 1);
        assert_eq!(find(&s, "-tag:dev").total, 1);
        assert_eq!(find(&s, "is:untagged").total, 1);
        assert_eq!(find(&s, "has:image").total, 1);
        assert_eq!(find(&s, "github").total, 1); // linked URL is searchable
        assert_eq!(find(&s, "from:@jack platform:x").total, 2);
        assert_eq!(find(&s, "swift -ıspanak").total, 0);
        assert_eq!(find(&s, "-istanbul").total, 1);
        let r = find(&s, "rust");
        assert_eq!(r.links.len(), 1);
        assert_eq!(r.links[0].url, "https://github.com/rust-lang/rust");
        assert_eq!(r.items[0].tags, vec!["Dev/Rust"]);
        assert_eq!(s.stats().unwrap().media_pending, 1);
    }

    #[test]
    fn upsert_keeps_user_state() {
        let mut s = Store::open_in_memory().unwrap();
        let mut a = post("1", "ilk");
        a.media = vec![Media::image("https://pbs.twimg.com/media/a.jpg")];
        s.upsert(&a).unwrap();
        s.set_note("x:1", Some("önemli")).unwrap();
        let mut m = a.media.clone();
        m[0].file = Some("ab.jpg".into());
        s.set_media("x:1", &m, None).unwrap();

        a.text = "güncel".into();
        assert!(!s.upsert(&a).unwrap().created);
        let got = s.get("x:1").unwrap().unwrap();
        assert_eq!(got.text, "güncel");
        assert_eq!(got.note.as_deref(), Some("önemli"));
        assert_eq!(got.media[0].file.as_deref(), Some("ab.jpg"));
        assert_eq!(s.stats().unwrap().media_pending, 0);

        // OCR: queued once the file is on disk, searchable once read, and
        // queued again if the pictures change.
        assert_eq!(s.ocr_pending(10).unwrap(), vec![("x:1".to_string(), vec!["ab.jpg".to_string()])]);
        s.set_ocr("x:1", "İndirim KODU: yaz2026").unwrap();
        assert!(s.ocr_pending(10).unwrap().is_empty());
        assert_eq!(s.search(&Query::parse("indirim kodu"), Sort::Default, 10, 0).unwrap().total, 1);
        assert_eq!(s.get("x:1").unwrap().unwrap().ocr.as_deref(), Some("İndirim KODU: yaz2026"));
        m.push(Media { file: Some("cd.jpg".into()), ..Media::image("https://pbs.twimg.com/media/b.jpg") });
        s.set_media("x:1", &m, None).unwrap();
        assert_eq!(s.ocr_pending(10).unwrap()[0].1.len(), 2);
    }

    #[test]
    fn tags_rename_and_cleanup() {
        let mut s = Store::open_in_memory().unwrap();
        s.upsert(&post("1", "a")).unwrap();
        s.upsert(&post("2", "b")).unwrap();
        s.edit_tags(&["x:1".into(), "x:2".into()], &["dev/rust".into(), "#oku".into()], &[]).unwrap();
        s.set_tags("x:2", &["Kod".into()]).unwrap();
        assert_eq!(s.rename_tag("dev", "kod").unwrap(), 1);
        let tags: Vec<(String, i64)> = s.tags().unwrap().into_iter().map(|t| (t.name, t.count)).collect();
        assert_eq!(tags, vec![("Kod".into(), 1), ("kod/rust".into(), 1), ("oku".into(), 1)]);
        assert_eq!(s.search(&Query::parse("tag:kod"), Sort::Default, 10, 0).unwrap().total, 2);
        let orphans = s.delete("x:1").unwrap();
        assert!(orphans.is_empty());
        assert_eq!(s.tags().unwrap().len(), 1);
    }

    #[test]
    fn negated_filters_and_link_filters() {
        let mut s = Store::open_in_memory().unwrap();
        let mut a = post("1", "rust notları");
        a.links = vec!["https://github.com/rust-lang/rust".into()];
        a.created_at = Some(1_600_000_000); // 2020
        s.upsert(&a).unwrap();
        let mut b = post("2", "tiktok videosu");
        b.platform = Platform::Tiktok;
        b.author_handle = Some("dhh".into());
        b.media = vec![Media { kind: MediaKind::Video, ..Media::image("https://www.tiktok.com/@dhh/video/2") }];
        b.links = vec!["https://github.com/other/repo".into()];
        s.upsert(&b).unwrap();
        s.add_link("https://manual.example/rust").unwrap();

        let total = |q: &str| s.search(&Query::parse(q), Sort::Default, 50, 0).unwrap().total;
        assert_eq!(total("from:@jack"), 1);
        assert_eq!(total("-from:@jack"), 1);
        assert_eq!(total("-@dhh"), 1);
        assert_eq!(total("platform:tiktok"), 1);
        assert_eq!(total("-platform:tiktok"), 1);
        assert_eq!(total("-has:video"), 1);
        assert_eq!(total("is:untagged"), 2);
        assert_eq!(total("-is:untagged"), 0);

        let links = |q: &str| s.links(q, 50, 0).unwrap().into_iter().map(|l| l.url).collect::<Vec<_>>();
        assert_eq!(links("").len(), 3);
        assert_eq!(links("-rust"), vec!["https://github.com/other/repo"]);
        assert_eq!(links("github after:2027"), Vec::<String>::new());
        assert_eq!(links("github before:2021"), vec!["https://github.com/rust-lang/rust"]);
        assert_eq!(links("platform:tiktok"), vec!["https://github.com/other/repo"]);
        // Item search shows links only through matching items.
        let r = s.search(&Query::parse("github -platform:tiktok"), Sort::Default, 50, 0).unwrap();
        assert_eq!(r.links.iter().map(|l| l.url.as_str()).collect::<Vec<_>>(), vec!["https://github.com/rust-lang/rust"]);
    }

    #[test]
    fn sorting_and_review() {
        let mut s = Store::open_in_memory().unwrap();
        for (id, posted, saved, author) in [("1", 300, 10, "zed"), ("2", 100, 30, "amy"), ("3", 200, 20, "Bob")] {
            let mut p = post(id, "kayıt");
            p.created_at = Some(posted);
            p.saved_at = saved;
            p.author_handle = Some(author.into());
            s.upsert(&p).unwrap();
        }
        let ids = |s: &Store, q: &str, sort: &str| -> Vec<String> {
            s.search(&Query::parse(q), Sort::parse(sort), 10, 0).unwrap().items.into_iter().map(|i| i.id).collect()
        };
        assert_eq!(ids(&s, "", ""), ["x:2", "x:3", "x:1"]);
        assert_eq!(ids(&s, "", "saved_asc"), ["x:1", "x:3", "x:2"]);
        assert_eq!(ids(&s, "", "posted"), ["x:1", "x:3", "x:2"]);
        assert_eq!(ids(&s, "kayıt", "posted_asc"), ["x:2", "x:3", "x:1"]);
        assert_eq!(ids(&s, "", "author"), ["x:2", "x:3", "x:1"]);
        let shuffled = ids(&s, "", "random:7");
        assert_eq!(shuffled.len(), 3);
        assert_eq!(shuffled, ids(&s, "", "random:7")); // stable per seed
        assert_eq!(ids(&s, "savedbefore:1970-01-02", "").len(), 3);
        assert_eq!(ids(&s, "savedafter:1970-01-01", "").len(), 0); // "after" a day: from the next one

        assert_eq!(s.set_reviewed(&["x:1".into()], true).unwrap(), 1);
        assert_eq!(ids(&s, "-is:reviewed", "saved_asc"), ["x:3", "x:2"]);
        assert_eq!(ids(&s, "is:reviewed", ""), ["x:1"]);
        s.set_reviewed(&["x:1".into()], false).unwrap();
        s.set_reviewed(&["x:2".into(), "x:3".into()], true).unwrap();
        assert_eq!(s.reset_reviewed().unwrap(), 2);
        assert_eq!(ids(&s, "-is:reviewed", "").len(), 3);
    }

    #[test]
    fn outside_video_queue() {
        let mut s = Store::open_in_memory().unwrap();
        let mut t = post("1", "tiktok");
        t.id = "tiktok:1".into();
        t.platform = Platform::Tiktok;
        t.media = vec![Media { kind: MediaKind::Video, ..Media::image("https://www.tiktok.com/@a/video/1") }];
        s.upsert(&t).unwrap();
        let mut x = post("2", "x video, a direct file");
        x.media = vec![Media { kind: MediaKind::Video, ..Media::image("https://video.twimg.com/a.mp4?tag=1") }];
        s.upsert(&x).unwrap();
        let st = s.stats().unwrap();
        assert_eq!((st.videos_missing, st.videos_queued), (1, 1));
        assert_eq!(s.external_video_queue(10).unwrap()[0].id, "tiktok:1");
        s.video_failed("tiktok:1").unwrap();
        assert!(s.external_video_queue(10).unwrap().is_empty()); // waits
        assert_eq!(s.stats().unwrap().videos_missing, 1);
        let mut done = t.media.clone();
        done[0].video_file = Some("0123456789abcdef0123456789abcdef.mp4".into());
        s.set_media("tiktok:1", &done, None).unwrap();
        assert_eq!(s.stats().unwrap().videos_missing, 0);
    }

    #[test]
    fn failed_link_lookups_are_retried() {
        let mut s = Store::open_in_memory().unwrap();
        let link = s.add_link("https://example.com/a").unwrap().unwrap();
        assert_eq!(s.links_to_enrich(10).unwrap().len(), 1);
        s.link_fetch_failed(link.id).unwrap();
        assert!(s.links_to_enrich(10).unwrap().is_empty()); // waits an hour
        s.conn.execute("UPDATE links SET fetch_tried_at = 0", []).unwrap();
        assert_eq!(s.links_to_enrich(10).unwrap().len(), 1);
        s.conn.execute("UPDATE links SET fetch_failures = 3", []).unwrap();
        assert!(s.links_to_enrich(10).unwrap().is_empty()); // given up
        s.conn.execute("UPDATE links SET fetch_failures = 0", []).unwrap();
        s.set_link_meta(link.id, Some("Başlık"), None, None).unwrap();
        assert!(s.links_to_enrich(10).unwrap().is_empty());
    }

    #[test]
    fn foreign_file_names_are_dropped() {
        let mut s = Store::open_in_memory().unwrap();
        let mut a = post("1", "a");
        let good = "0123456789abcdef0123456789abcdef.jpg";
        a.media = vec![
            Media { file: Some("../../../tmp/victim".into()), ..Media::image("https://pbs.twimg.com/media/a.jpg") },
            Media { file: Some(good.into()), video_file: Some("/etc/passwd".into()), ..Media::image("https://pbs.twimg.com/media/b.jpg") },
        ];
        s.upsert(&a).unwrap();
        let got = s.get("x:1").unwrap().unwrap();
        assert_eq!(got.media[0].file, None);
        assert_eq!(got.media[1].file.as_deref(), Some(good));
        assert_eq!(got.media[1].video_file, None);
        assert_eq!(s.delete("x:1").unwrap(), vec![good.to_string()]);
    }

    #[test]
    fn delete_cleans_up_links_and_known_files() {
        let mut s = Store::open_in_memory().unwrap();
        let mut a = post("1", "a");
        a.links = vec!["https://only-here.example/".into(), "https://shared.example/".into()];
        let f = "0123456789abcdef0123456789abcdef.jpg";
        a.media = vec![Media { file: Some(f.into()), ..Media::image("https://pbs.twimg.com/media/a.jpg") }];
        s.upsert(&a).unwrap();
        let mut b = post("2", "b");
        b.links = vec!["https://shared.example/".into()];
        s.upsert(&b).unwrap();
        s.set_media("x:1", &a.media, None).unwrap();
        assert_eq!(s.known_file("https://pbs.twimg.com/media/a.jpg").unwrap().as_deref(), Some(f));

        s.delete("x:1").unwrap();
        let urls: Vec<String> = s.links("", 10, 0).unwrap().into_iter().map(|l| l.url).collect();
        assert_eq!(urls, vec!["https://shared.example"]);
        assert_eq!(s.known_file("https://pbs.twimg.com/media/a.jpg").unwrap(), None);
    }

    #[test]
    fn retry_media_only_queues_missing_files() {
        let mut s = Store::open_in_memory().unwrap();
        let mut done = post("1", "a");
        done.media = vec![Media { file: Some("0123456789abcdef0123456789abcdef.jpg".into()), ..Media::image("https://pbs.twimg.com/media/a.jpg") }];
        s.upsert(&done).unwrap();
        let mut missing = post("2", "b");
        missing.media = vec![Media::image("https://pbs.twimg.com/media/b.jpg")];
        s.upsert(&missing).unwrap();
        s.set_media("x:2", &missing.media, None).unwrap(); // a failed download
        s.upsert(&post("3", "no media")).unwrap();
        assert_eq!(s.stats().unwrap().media_pending, 0);
        assert_eq!(s.retry_media().unwrap(), 1);
        assert_eq!(s.pending_media(10).unwrap()[0].id, "x:2");
    }

    #[test]
    fn reimport_keeps_quote_and_its_files() {
        let mut s = Store::open_in_memory().unwrap();
        let mut q = post("9", "alıntı");
        q.media = vec![Media::image("https://pbs.twimg.com/media/q.jpg")];
        let mut a = post("1", "ana");
        a.quote = Some(Box::new(q.clone()));
        s.upsert(&a).unwrap();
        let mut downloaded = q.clone();
        downloaded.media[0].file = Some("0123456789abcdef0123456789abcdef.jpg".into());
        s.set_media("x:1", &[], Some(&downloaded)).unwrap();

        s.upsert(&a).unwrap(); // same payload again
        let got = s.get("x:1").unwrap().unwrap();
        assert!(got.quote.as_ref().unwrap().media[0].file.is_some());
        assert_eq!(s.stats().unwrap().media_pending, 0);
        a.quote = None; // the quoted post was deleted
        s.upsert(&a).unwrap();
        assert_eq!(s.get("x:1").unwrap().unwrap().quote.unwrap().text, "alıntı");
    }

    #[test]
    fn migrates_old_libraries() {
        let path = std::env::temp_dir().join(format!("wm-migrate-{}.sqlite", std::process::id()));
        let _ = std::fs::remove_file(&path);
        {
            let mut s = Store::open(&path).unwrap();
            let mut a = post("1", "eski");
            a.media = vec![Media { file: Some("0123456789abcdef0123456789abcdef.jpg".into()), ..Media::image("https://pbs.twimg.com/media/a.jpg") }];
            a.links = vec!["https://example.com/".into()];
            s.upsert(&a).unwrap();
            // Back to a v3 library: no OCR column, no known files, no link retries.
            s.conn
                .execute_batch(
                    "ALTER TABLE items DROP COLUMN ocr; ALTER TABLE items DROP COLUMN reviewed_at;
                     ALTER TABLE items DROP COLUMN video_tries; ALTER TABLE items DROP COLUMN video_tried_at; DROP TABLE media_files;
                     ALTER TABLE links DROP COLUMN fetch_failures; ALTER TABLE links DROP COLUMN fetch_tried_at;
                     DROP INDEX IF EXISTS items_folder; ALTER TABLE items DROP COLUMN folder_id; DROP TABLE IF EXISTS folders;
                     PRAGMA user_version = 3;",
                )
                .unwrap();
        }
        let mut s = Store::open(&path).unwrap();
        let v: i64 = s.conn.query_row("PRAGMA user_version", [], |r| r.get(0)).unwrap();
        assert_eq!(v, SCHEMA_VERSION);
        assert_eq!(s.known_file("https://pbs.twimg.com/media/a.jpg").unwrap().as_deref(), Some("0123456789abcdef0123456789abcdef.jpg"));
        assert_eq!(s.ocr_pending(10).unwrap().len(), 1);
        assert_eq!(s.links_to_enrich(10).unwrap().len(), 1);
        assert_eq!(s.search(&Query::parse("eski"), Sort::Default, 10, 0).unwrap().total, 1);
        drop(s);
        for ext in ["", "-wal", "-shm"] {
            let _ = std::fs::remove_file(format!("{}{ext}", path.display()));
        }
    }

    #[test]
    fn folder_crud_and_search() {
        let mut s = Store::open_in_memory().unwrap();
        let f1 = s.add_folder("Yazılım").unwrap();
        assert_eq!(f1.name, "Yazılım");
        assert_eq!(f1.count, 0);

        let item = post("1", "rust programlama");
        s.upsert(&item).unwrap();
        s.move_to_folder("x:1", Some(f1.id)).unwrap();

        let folders = s.folders().unwrap();
        assert_eq!(folders.len(), 1);
        assert_eq!(folders[0].count, 1);

        let res = s.search(&Query::parse("folder:Yazılım"), Sort::Default, 10, 0).unwrap();
        assert_eq!(res.total, 1);

        let res_id = s.search(&Query::parse(&format!("folder:{}", f1.id)), Sort::Default, 10, 0).unwrap();
        assert_eq!(res_id.total, 1);

        s.rename_folder(f1.id, "Geliştirme").unwrap();
        assert_eq!(s.folders().unwrap()[0].name, "Geliştirme");

        s.delete_folder(f1.id).unwrap();
        assert_eq!(s.folders().unwrap().len(), 0);
        let item_after = s.get("x:1").unwrap().unwrap();
        assert_eq!(item_after.folder_id, None);
    }
}
