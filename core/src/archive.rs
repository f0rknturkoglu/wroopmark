//! Bulk imports from files: browser bookmarks (`bookmarks.html`), the data
//! downloads TikTok, Instagram and X hand out, and CSV exports of other
//! bookmark apps (Pocket, Raindrop…), as a `.zip`, a folder or one file.
//!
//! Most of these only carry links and dates, so they become *stubs*: items
//! with the right id and URL whose text, author and media are fetched later
//! in the background (see `Library::fill_stubs`). Browsing / watch history
//! is skipped on purpose; it is not something you saved.

use std::path::{Path, PathBuf};
use std::sync::LazyLock;

use chrono::NaiveDateTime;
use regex::Regex;
use serde_json::Value;

use crate::model::{Item, Media, MediaKind, Platform};
use crate::text::{item_id_for_url, normalize_url, tidy};

/// One saved thing found in an archive.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Stub {
    pub url: String,
    pub title: Option<String>,
    pub author: Option<String>,
    pub text: Option<String>,
    /// When it was saved / liked (unix seconds).
    pub at: Option<i64>,
    pub tags: Vec<String>,
    /// Folder path from the source (`Dev/Rust`), bookmarks only.
    pub folder: Option<String>,
}

#[derive(Debug, Default)]
pub struct Found {
    pub stubs: Vec<Stub>,
    /// `file name: count` for each file that had something.
    pub sources: Vec<(String, usize)>,
}

static BOOKMARK_TOKEN: LazyLock<Option<Regex>> =
    LazyLock::new(|| Regex::new(r"(?s)<[hH]3([^>]*)>(.*?)</[hH]3>|<[dD][lL][^>]*>|</[dD][lL]>|<[aA]\s([^>]*)>(.*?)</[aA]>").ok());
static ATTR: LazyLock<Option<Regex>> = LazyLock::new(|| Regex::new(r#"([A-Za-z_]+)\s*=\s*"([^"]*)""#).ok());
static TIKTOK_VIDEO: LazyLock<Option<Regex>> = LazyLock::new(|| Regex::new(r"tiktokv?\.com/.*?(?:video|v)/(\d{8,25})").ok());
static TAG_STRIP: LazyLock<Option<Regex>> = LazyLock::new(|| Regex::new(r"(?s)<[^>]*>").ok());

fn unescape(s: &str) -> String {
    let no_tags = TAG_STRIP.as_ref().map(|re| re.replace_all(s, "").into_owned()).unwrap_or_else(|| s.to_string());
    no_tags.replace("&quot;", "\"").replace("&#39;", "'").replace("&lt;", "<").replace("&gt;", ">").replace("&amp;", "&").trim().to_string()
}

fn is_web(url: &str) -> bool {
    url.starts_with("http://") || url.starts_with("https://")
}

/// Top-level folders every browser has; their names say nothing.
const BOOKMARK_ROOTS: [&str; 14] = [
    "bookmarks bar",
    "bookmarks toolbar",
    "bookmarks menu",
    "other bookmarks",
    "mobile bookmarks",
    "favorites bar",
    "favourites bar",
    "yer işareti çubuğu",
    "yer işaretleri çubuğu",
    "diğer yer işaretleri",
    "mobil yer işaretleri",
    "yer imleri çubuğu",
    "favoriler çubuğu",
    "bookmarks",
];

/// The Netscape bookmark file every browser exports.
pub fn parse_bookmarks_html(html: &str) -> Vec<Stub> {
    let (Some(token), Some(attr)) = (BOOKMARK_TOKEN.as_ref(), ATTR.as_ref()) else { return vec![] };
    let mut stack: Vec<Option<String>> = vec![];
    let mut pending: Option<String> = None;
    let mut out = vec![];
    for cap in token.captures_iter(html) {
        let whole = cap.get(0).map(|m| m.as_str()).unwrap_or("");
        if let Some(name) = cap.get(2) {
            let attrs = cap.get(1).map(|m| m.as_str()).unwrap_or("");
            let name = unescape(name.as_str());
            let root = stack.iter().flatten().next().is_none()
                && (attrs.to_ascii_lowercase().contains("personal_toolbar_folder") || BOOKMARK_ROOTS.contains(&name.to_lowercase().as_str()));
            pending = Some(if root { String::new() } else { name.replace('/', "-") });
        } else if whole.len() >= 4 && whole.get(..4).is_some_and(|h| h.eq_ignore_ascii_case("</dl")) {
            stack.pop();
        } else if whole.len() >= 3 && whole.get(..3).is_some_and(|h| h.eq_ignore_ascii_case("<dl")) {
            stack.push(pending.take());
        } else if let Some(a) = cap.get(3) {
            let mut href = None;
            let mut at = None;
            let mut tags = vec![];
            for m in attr.captures_iter(a.as_str()) {
                let key = m.get(1).map(|k| k.as_str().to_ascii_lowercase()).unwrap_or_default();
                let val = m.get(2).map(|v| v.as_str()).unwrap_or("");
                match key.as_str() {
                    "href" => href = Some(unescape(val)),
                    "add_date" => at = val.parse::<i64>().ok().map(|t| if t > 100_000_000_000 { t / 1_000_000 } else { t }),
                    "tags" => tags = val.split(',').map(unescape).filter(|t| !t.is_empty()).collect(),
                    _ => {}
                }
            }
            let Some(url) = href.filter(|u| is_web(u)) else { continue };
            let folder: Vec<&str> = stack.iter().flatten().map(String::as_str).filter(|s| !s.is_empty()).collect();
            let title = unescape(cap.get(4).map(|m| m.as_str()).unwrap_or(""));
            out.push(Stub {
                url,
                title: (!title.is_empty()).then_some(title),
                at,
                tags,
                folder: (!folder.is_empty()).then(|| folder.join("/")),
                ..Default::default()
            });
        }
    }
    out
}

/// Which tag a section of a data download gets; `None` = skip it.
fn section_tag(platform: &str, section: &str) -> Option<Option<String>> {
    let s = section.to_lowercase().replace(['_', '-'], " ");
    if s.contains("history") || s.contains("gecmis") || s.contains("geçmiş") {
        return None;
    }
    let tag = if s.contains("like") || s.contains("begen") || s.contains("beğen") {
        Some(match platform {
            "tiktok" => "tiktok/begenilenler",
            "x" => "x/begenilenler",
            _ => "instagram/begenilenler",
        })
    } else if s.contains("favorite") || s.contains("favori") || s.contains("saved") || s.contains("kaydedil") || s.contains("bookmark") {
        Some(match platform {
            "tiktok" => "tiktok/favoriler",
            "x" => "x/yer-imleri",
            _ => "instagram/kaydedilenler",
        })
    } else if platform == "tiktok" && (s.contains("post") || s.contains("video")) {
        Some("tiktok/videolarim")
    } else {
        None
    };
    Some(tag.map(str::to_string))
}

fn tiktok_url(id: &str) -> String {
    format!("https://www.tiktok.com/@/video/{id}")
}

fn tiktok_id(link: &str) -> Option<String> {
    TIKTOK_VIDEO.as_ref()?.captures(link)?.get(1).map(|m| m.as_str().to_string())
}

/// "2023-01-31 18:04:05" (UTC), as TikTok writes dates.
fn tiktok_date(s: &str) -> Option<i64> {
    NaiveDateTime::parse_from_str(s.trim(), "%Y-%m-%d %H:%M:%S").ok().map(|d| d.and_utc().timestamp())
}

type Visit<'f> = dyn FnMut(&serde_json::Map<String, Value>, &[&str]) + 'f;

fn walk<'a>(v: &'a Value, path: &mut Vec<&'a str>, f: &mut Visit<'_>) {
    match v {
        Value::Object(map) => {
            f(map, path);
            for (k, child) in map {
                path.push(k.as_str());
                walk(child, path, f);
                path.pop();
            }
        }
        Value::Array(items) => {
            for child in items {
                walk(child, path, f);
            }
        }
        _ => {}
    }
}

/// TikTok's "Download your data" JSON (`user_data_tiktok.json`).
pub fn parse_tiktok_json(v: &Value) -> Vec<Stub> {
    let mut out = vec![];
    walk(v, &mut vec![], &mut |map, path| {
        let link = ["Link", "link", "VideoLink", "videoLink"].iter().find_map(|k| map.get(*k).and_then(Value::as_str));
        let Some(id) = link.and_then(tiktok_id) else { return };
        let Some(tag) = section_tag("tiktok", &path.join(" ")) else { return };
        let at = ["Date", "date"].iter().find_map(|k| map.get(*k).and_then(Value::as_str)).and_then(tiktok_date);
        out.push(Stub { url: tiktok_url(&id), at, tags: tag.into_iter().collect(), ..Default::default() });
    });
    out
}

/// TikTok's TXT download: `Date: …` / `Link: …` pairs; the file name is the section.
pub fn parse_tiktok_txt(text: &str, section: &str) -> Vec<Stub> {
    let Some(tag) = section_tag("tiktok", section) else { return vec![] };
    let mut out = vec![];
    let mut date = None;
    for line in text.lines() {
        let line = line.trim();
        if let Some(d) = line.strip_prefix("Date:") {
            date = tiktok_date(d);
        } else if let Some(id) = line.strip_prefix("Link:").or_else(|| line.strip_prefix("Video Link:")).and_then(tiktok_id) {
            out.push(Stub { url: tiktok_url(&id), at: date.take(), tags: tag.clone().into_iter().collect(), ..Default::default() });
        }
    }
    out
}

fn is_instagram_post(url: &str) -> bool {
    url.contains("instagram.com/") && ["/p/", "/reel/", "/reels/", "/tv/"].iter().any(|p| url.contains(p))
}

/// Instagram's data download (`saved_posts.json`, `liked_posts.json`).
pub fn parse_instagram_json(v: &Value, section: &str) -> Vec<Stub> {
    let Some(tag) = section_tag("instagram", section) else { return vec![] };
    let mut out: Vec<Stub> = vec![];
    // The username sits on the entry, the link one or two levels below it.
    fn find(v: &Value, author: Option<&str>, tag: &Option<String>, out: &mut Vec<Stub>) {
        match v {
            Value::Object(map) => {
                let author = map.get("title").and_then(Value::as_str).filter(|t| !t.is_empty()).or(author);
                if let Some(href) = map.get("href").and_then(Value::as_str).filter(|h| is_instagram_post(h)) {
                    out.push(Stub {
                        url: href.to_string(),
                        author: author.map(str::to_string),
                        at: map.get("timestamp").and_then(Value::as_i64),
                        tags: tag.clone().into_iter().collect(),
                        ..Default::default()
                    });
                }
                for child in map.values() {
                    find(child, author, tag, out);
                }
            }
            Value::Array(items) => items.iter().for_each(|c| find(c, author, tag, out)),
            _ => {}
        }
    }
    find(v, None, &tag, &mut out);
    out
}

/// X's archive (`data/like.js`, `data/bookmark.js`): JavaScript that assigns
/// a JSON array.
pub fn parse_x_js(text: &str, section: &str) -> Vec<Stub> {
    let Some(tag) = section_tag("x", section) else { return vec![] };
    let Some(json) = text.find(['[', '{']).and_then(|i| text.get(i..)) else { return vec![] };
    let Ok(v) = serde_json::from_str::<Value>(json) else { return vec![] };
    let mut out = vec![];
    walk(&v, &mut vec![], &mut |map, _| {
        let Some(id) = map.get("tweetId").and_then(Value::as_str).filter(|i| i.chars().all(|c| c.is_ascii_digit())) else { return };
        let url = map.get("expandedUrl").and_then(Value::as_str).filter(|u| u.contains("/status/")).map(str::to_string);
        out.push(Stub {
            url: url.unwrap_or_else(|| format!("https://x.com/i/status/{id}")),
            text: map.get("fullText").and_then(Value::as_str).map(tidy),
            tags: tag.clone().into_iter().collect(),
            ..Default::default()
        });
    });
    out
}

/// Splits CSV text into records (quotes, escaped quotes, newlines in fields).
fn csv_records(text: &str) -> Vec<Vec<String>> {
    let mut rows = vec![];
    let mut row = vec![];
    let mut field = String::new();
    let mut quoted = false;
    let mut chars = text.trim_start_matches('\u{feff}').chars().peekable();
    while let Some(c) = chars.next() {
        match (c, quoted) {
            ('"', true) if chars.peek() == Some(&'"') => {
                field.push('"');
                chars.next();
            }
            ('"', _) => quoted = !quoted,
            (',', false) => row.push(std::mem::take(&mut field)),
            ('\n', false) => {
                row.push(std::mem::take(&mut field));
                rows.push(std::mem::take(&mut row));
            }
            ('\r', false) => {}
            (c, _) => field.push(c),
        }
    }
    if !field.is_empty() || !row.is_empty() {
        row.push(field);
        rows.push(row);
    }
    rows
}

fn parse_time(s: &str) -> Option<i64> {
    let s = s.trim();
    if let Ok(n) = s.parse::<i64>() {
        return Some(if n > 100_000_000_000 { n / 1000 } else { n });
    }
    chrono::DateTime::parse_from_rfc3339(s).ok().map(|d| d.timestamp()).or_else(|| tiktok_date(s))
}

/// A CSV with a URL column (Pocket, Raindrop, Reddit's `saved_posts.csv`…).
pub fn parse_csv(text: &str) -> Vec<Stub> {
    let rows = csv_records(text);
    let Some((head, body)) = rows.split_first() else { return vec![] };
    let col = |names: &[&str]| head.iter().position(|h| names.contains(&h.trim().to_lowercase().as_str()));
    let Some(url_col) = col(&["url", "link", "href", "permalink", "address", "adres"]) else { return vec![] };
    let title_col = col(&["title", "name", "başlık", "baslik"]);
    let tags_col = col(&["tags", "etiketler"]);
    let time_col = col(&["time_added", "created", "created_at", "date", "added", "saved_at"]);
    let folder_col = col(&["folder", "collection", "klasör"]);
    let note_col = col(&["note", "excerpt", "not"]);
    body.iter()
        .filter_map(|r| {
            let get = |c: Option<usize>| c.and_then(|c| r.get(c)).map(|s| s.trim()).filter(|s| !s.is_empty());
            let mut url = get(Some(url_col))?.to_string();
            if url.starts_with("/r/") {
                url = format!("https://www.reddit.com{url}");
            }
            if !is_web(&url) {
                return None;
            }
            Some(Stub {
                url,
                title: get(title_col).map(str::to_string),
                text: get(note_col).map(str::to_string),
                at: get(time_col).and_then(parse_time),
                tags: get(tags_col)
                    .map(|t| t.split(['|', ',']).map(str::trim).filter(|t| !t.is_empty()).map(str::to_string).collect())
                    .unwrap_or_default(),
                folder: get(folder_col).map(|f| f.replace(" / ", "/")),
                ..Default::default()
            })
        })
        .collect()
}

/// Parses one file by what it looks like; anything unknown gives nothing.
pub fn parse_file(path: &Path) -> Vec<Stub> {
    let name = path.file_name().and_then(|n| n.to_str()).unwrap_or("").to_lowercase();
    let stem = path.file_stem().and_then(|n| n.to_str()).unwrap_or("").to_lowercase();
    let ext = path.extension().and_then(|e| e.to_str()).unwrap_or("").to_lowercase();
    if !matches!(ext.as_str(), "html" | "htm" | "json" | "js" | "txt" | "csv") {
        return vec![];
    }
    if std::fs::metadata(path).map(|m| m.len() > 400 * 1024 * 1024).unwrap_or(true) {
        return vec![];
    }
    let Ok(bytes) = std::fs::read(path) else { return vec![] };
    let text = String::from_utf8_lossy(&bytes);
    let parent = path.parent().and_then(|p| p.to_str()).unwrap_or("").to_lowercase();
    match ext.as_str() {
        "html" | "htm" if text.contains("NETSCAPE-Bookmark-file") || text.to_ascii_lowercase().contains("<dt><a ") => parse_bookmarks_html(&text),
        "json" => {
            let Ok(v) = serde_json::from_str::<Value>(&text) else { return vec![] };
            if text.contains("tiktok") {
                parse_tiktok_json(&v)
            } else if text.contains("instagram.com") {
                parse_instagram_json(&v, &stem)
            } else {
                vec![]
            }
        }
        "js" if text.contains("window.YTD") => parse_x_js(&text, &stem),
        "txt" if text.contains("tiktok") => parse_tiktok_txt(&text, &format!("{parent} {name}")),
        "csv" => parse_csv(&text),
        _ => vec![],
    }
}

fn walk_files(dir: &Path, depth: usize, out: &mut Vec<PathBuf>) {
    if depth > 8 {
        return;
    }
    let Ok(entries) = std::fs::read_dir(dir) else { return };
    let mut entries: Vec<_> = entries.flatten().map(|e| e.path()).collect();
    entries.sort();
    for p in entries {
        let hidden = p.file_name().and_then(|n| n.to_str()).is_some_and(|n| n.starts_with('.') || n == "__MACOSX");
        if hidden {
            continue;
        }
        if p.is_dir() {
            walk_files(&p, depth + 1, out);
        } else {
            out.push(p);
        }
    }
}

/// Reads a `.zip`, a folder or a single file. Zips are unpacked with the
/// system's `ditto` into a temporary folder that is removed afterwards.
pub fn scan(path: &Path) -> std::io::Result<Found> {
    let is_zip = path.extension().and_then(|e| e.to_str()).is_some_and(|e| e.eq_ignore_ascii_case("zip"));
    let mut tmp = None;
    let root = if is_zip {
        let dir = std::env::temp_dir().join(format!("wroopmark-import-{}-{}", std::process::id(), crate::text::now()));
        std::fs::create_dir_all(&dir)?;
        let status = std::process::Command::new("/usr/bin/ditto").arg("-x").arg("-k").arg(path).arg(&dir).status()?;
        if !status.success() {
            let _ = std::fs::remove_dir_all(&dir);
            return Err(std::io::Error::other("zip açılamadı"));
        }
        tmp = Some(dir.clone());
        dir
    } else {
        path.to_path_buf()
    };
    let mut files = vec![];
    if root.is_dir() {
        walk_files(&root, 0, &mut files);
    } else {
        files.push(root.clone());
    }
    let mut found = Found::default();
    for f in &files {
        let stubs = parse_file(f);
        if !stubs.is_empty() {
            let shown = f.strip_prefix(&root).unwrap_or(f).display().to_string();
            found.sources.push((if shown.is_empty() { f.display().to_string() } else { shown }, stubs.len()));
            found.stubs.extend(stubs);
        }
    }
    if let Some(dir) = tmp {
        let _ = std::fs::remove_dir_all(dir);
    }
    Ok(found)
}

/// The item a stub becomes before its details are fetched.
pub fn to_item(stub: &Stub) -> Item {
    let url = normalize_url(&stub.url).unwrap_or_else(|| stub.url.clone());
    let (platform, id) = item_id_for_url(&url);
    let mut media = vec![];
    if platform == Platform::Tiktok {
        let mut m = Media::image(url.clone());
        m.kind = MediaKind::Video;
        media.push(m);
    }
    let author = stub.author.as_deref().map(|a| a.trim_start_matches('@').to_string());
    Item {
        id,
        platform,
        url,
        author_handle: author,
        title: stub.title.clone(),
        text: stub.text.clone().unwrap_or_default(),
        saved_at: stub.at.unwrap_or(0),
        media,
        tags: stub.tags.clone(),
        stub: true,
        ..Default::default()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_bookmarks_html() {
        let html = r#"<!DOCTYPE NETSCAPE-Bookmark-file-1>
<TITLE>Bookmarks</TITLE><H1>Bookmarks</H1>
<DL><p>
  <DT><H3 ADD_DATE="1" PERSONAL_TOOLBAR_FOLDER="true">Bookmarks bar</H3>
  <DL><p>
    <DT><A HREF="https://a.com/x?y=1&amp;z=2" ADD_DATE="1700000000">A &amp; B</A>
    <DT><H3>Dev</H3>
    <DL><p>
      <DT><A HREF="https://github.com/rust-lang/rust" ADD_DATE="1700000001" TAGS="rust,dil">Rust</A>
      <DT><A HREF="javascript:alert(1)">bad</A>
    </DL><p>
  </DL><p>
  <DT><A HREF="https://root.com/">Root</A>
</DL>"#;
        let b = parse_bookmarks_html(html);
        assert_eq!(b.len(), 3);
        assert_eq!(
            b.first().map(|s| (s.url.as_str(), s.title.as_deref(), s.folder.as_deref())),
            Some(("https://a.com/x?y=1&z=2", Some("A & B"), None))
        );
        assert_eq!(b.get(1).and_then(|s| s.folder.as_deref()), Some("Dev"));
        assert_eq!(b.get(1).map(|s| s.tags.clone()), Some(vec!["rust".to_string(), "dil".to_string()]));
        assert_eq!(b.get(2).and_then(|s| s.folder.as_deref()), None);
    }

    #[test]
    fn reads_platform_downloads() {
        let tt: Value = serde_json::from_str(
            r#"{"Activity":{"Favorite Videos":{"FavoriteVideoList":[{"Date":"2023-01-31 18:04:05","Link":"https://www.tiktokv.com/share/video/7194000000000000001/"}]},
                "Like List":{"ItemFavoriteList":[{"date":"2023-02-01 10:00:00","link":"https://www.tiktokv.com/share/video/7194000000000000002/"}]},
                "Video Browsing History":{"VideoList":[{"Date":"2023-02-01 10:00:00","Link":"https://www.tiktokv.com/share/video/7194000000000000003/"}]}}}"#,
        )
        .unwrap_or_default();
        let s = parse_tiktok_json(&tt);
        assert_eq!(s.len(), 2);
        assert_eq!(s.first().map(|x| x.url.as_str()), Some("https://www.tiktok.com/@/video/7194000000000000001"));
        assert_eq!(s.first().map(|x| x.tags.clone()), Some(vec!["tiktok/favoriler".to_string()]));
        assert_eq!(s.get(1).map(|x| x.tags.clone()), Some(vec!["tiktok/begenilenler".to_string()]));
        let item = to_item(s.first().unwrap_or(&Stub::default()));
        assert_eq!(item.id, "tiktok:7194000000000000001");
        assert_eq!(item.saved_at, 1675188245);

        let txt = "Date: 2023-01-31 18:04:05\nLink: https://www.tiktokv.com/share/video/7194000000000000009/\n\n";
        assert_eq!(parse_tiktok_txt(txt, "Activity/Favorite Videos.txt").len(), 1);
        assert!(parse_tiktok_txt(txt, "Watch History.txt").is_empty());

        let ig: Value = serde_json::from_str(
            r#"{"saved_saved_media":[{"title":"someone","string_map_data":{"Saved on":{"href":"https://www.instagram.com/p/ABC123/","timestamp":1700000000}}}]}"#,
        )
        .unwrap_or_default();
        let s = parse_instagram_json(&ig, "saved_posts");
        assert_eq!(s.first().map(|x| (x.author.as_deref(), x.at)), Some((Some("someone"), Some(1700000000))));
        assert_eq!(to_item(s.first().unwrap_or(&Stub::default())).id, "instagram:ABC123");

        let js = r#"window.YTD.like.part0 = [{"like":{"tweetId":"123","fullText":"merhaba","expandedUrl":"https://twitter.com/i/web/status/123"}}]"#;
        let s = parse_x_js(js, "like");
        assert_eq!(s.first().map(|x| (x.text.as_deref(), x.tags.clone())), Some((Some("merhaba"), vec!["x/begenilenler".to_string()])));
        assert_eq!(to_item(s.first().unwrap_or(&Stub::default())).id, "x:123");

        let csv = "title,url,time_added,tags\n\"A, b\",https://e.com/1,1700000000,a|b\nnope,ftp://x,1,\n";
        let s = parse_csv(csv);
        assert_eq!(s.len(), 1);
        assert_eq!(s.first().map(|x| (x.title.as_deref(), x.tags.len())), Some((Some("A, b"), 2)));
    }
}
