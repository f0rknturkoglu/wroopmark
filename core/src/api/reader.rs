//! The readable copy of web pages (v0.8): made when a page is saved or,
//! for older saves and other devices' saves, by the background pass, which
//! also brings the copy's pictures down so it reads offline.

use std::sync::LazyLock;

use regex::Regex;
use serde::Deserialize;
use serde_json::json;

use crate::model::Highlight;

use super::*;

/// `<img … src="…">` (double or single quotes).
static IMG_SRC_RE: LazyLock<Option<Regex>> = LazyLock::new(|| Regex::new(r#"(<img\b[^>]*?\bsrc\s*=\s*)(["'])([^"']+)(["'])"#).ok());
/// `srcset` / `sizes`, which would make the reader fetch other sizes.
static SRCSET_RE: LazyLock<Option<Regex>> = LazyLock::new(|| Regex::new(r#"\s(?:srcset|sizes)\s*=\s*("[^"]*"|'[^']*')"#).ok());

/// At most this many pictures of one page are kept.
const MAX_IMAGES: usize = 40;

fn image_urls(html: &str) -> Vec<String> {
    let Some(re) = IMG_SRC_RE.as_ref() else { return vec![] };
    let mut out: Vec<String> = re
        .captures_iter(html)
        .filter_map(|c| c.get(3).map(|m| m.as_str().replace("&amp;", "&")))
        .filter(|u| u.starts_with("http://") || u.starts_with("https://"))
        .collect();
    out.dedup();
    out.truncate(MAX_IMAGES);
    out
}

impl Library {
    /// Adds, changes (`note`, `color`) or removes (`delete`) one highlight;
    /// returns the item's highlights after.
    pub fn edit_highlight(&self, e: HighlightEdit) -> Result<Vec<Highlight>> {
        let mut store = self.lock_store()?;
        let mut list = store.highlights(&e.id)?;
        match e.hid {
            Some(hid) if e.delete => list.retain(|h| h.id != hid),
            Some(hid) => {
                if let Some(h) = list.iter_mut().find(|h| h.id == hid) {
                    if let Some(n) = e.note {
                        h.note = Some(n).filter(|n| !n.trim().is_empty());
                    }
                    if let Some(c) = e.color {
                        h.color = c;
                    }
                }
            }
            None => {
                let quote = e.quote.unwrap_or_default();
                if quote.trim().is_empty() {
                    return Ok(list);
                }
                let at = crate::text::now();
                list.push(Highlight {
                    id: format!("{at:x}{}", list.len()),
                    quote,
                    prefix: e.prefix.unwrap_or_default(),
                    note: e.note.filter(|n| !n.trim().is_empty()),
                    color: e.color.unwrap_or_else(|| "yellow".into()),
                    at,
                });
            }
        }
        store.set_highlights(&e.id, &list)?;
        Ok(list)
    }

    /// Makes missing readable copies and brings their pictures down, up to
    /// `limit` pages. Returns how many were handled.
    pub fn fill_articles(&self, limit: i64) -> Result<usize> {
        if self.media_paused() {
            return Ok(0);
        }
        let todo = self.lock_store()?.articles_to_fill(limit)?;
        let mut done = 0;
        for (id, url, article) in todo {
            if self.stopping.load(Ordering::Acquire) {
                break;
            }
            let html = match article {
                Some(a) => a,
                None => {
                    // An empty copy marks the page as tried.
                    let made = self.fetcher.page(&url).ok().and_then(|p| p.article).unwrap_or_default();
                    self.lock_store()?.set_article(&id, &made, made.is_empty())?;
                    made
                }
            };
            for src in image_urls(&html) {
                if self.stopping.load(Ordering::Acquire) {
                    return Ok(done);
                }
                if self.lock_store()?.known_file(&src)?.is_some_and(|f| self.media.contains(&f)) {
                    continue;
                }
                if let Ok(name) = self.fetcher.download(&self.media, &src) {
                    self.lock_store()?.remember_url(&src, &name)?;
                }
            }
            if !html.is_empty() {
                self.lock_store()?.set_article_ready(&id)?;
            }
            done += 1;
        }
        Ok(done)
    }

    /// The readable copy for the reader: pictures that are on this device
    /// point at the media store (`wroopmark-media:///<name>`), and `srcset`
    /// is dropped so nothing else is fetched.
    pub fn article_for_reader(&self, id: &str) -> Result<Option<String>> {
        let Some(html) = self.lock_store()?.article(id)?.filter(|a| !a.is_empty()) else { return Ok(None) };
        let store = self.lock_store()?;
        let html = match IMG_SRC_RE.as_ref() {
            Some(re) => re
                .replace_all(&html, |c: &regex::Captures<'_>| {
                    let (head, q, src) =
                        (c.get(1).map_or("", |m| m.as_str()), c.get(2).map_or("\"", |m| m.as_str()), c.get(3).map_or("", |m| m.as_str()));
                    let url = src.replace("&amp;", "&");
                    match store.known_file(&url).ok().flatten().filter(|f| self.media.contains(f)) {
                        Some(name) => format!("{head}{q}wroopmark-media:///{name}{q}"),
                        None => format!("{head}{q}{src}{q}"),
                    }
                })
                .into_owned(),
            None => html,
        };
        Ok(Some(match SRCSET_RE.as_ref() {
            Some(re) => re.replace_all(&html, "").into_owned(),
            None => html,
        }))
    }
}

#[derive(Deserialize)]
pub struct HighlightEdit {
    pub id: String,
    #[serde(default)]
    pub hid: Option<String>,
    #[serde(default)]
    pub quote: Option<String>,
    #[serde(default)]
    pub prefix: Option<String>,
    #[serde(default)]
    pub note: Option<String>,
    #[serde(default)]
    pub color: Option<String>,
    #[serde(default)]
    pub delete: bool,
}

pub(super) fn dispatch<S: Sink>(lib: &Arc<Library>, cmd: &str, req: Req<'_>) -> Option<Result<S::Out>> {
    #[derive(Deserialize)]
    struct Id {
        id: String,
    }
    #[derive(Deserialize)]
    struct Limit {
        #[serde(default = "five")]
        limit: i64,
    }
    fn five() -> i64 {
        5
    }
    Some(match cmd {
        "article" => req.parse::<Id>().and_then(|r| lib.article_for_reader(&r.id)).and_then(|html| S::ok(json!({ "html": html }))),
        "highlights" => req.parse::<Id>().and_then(|r| Ok(lib.lock_store()?.highlights(&r.id)?)).and_then(S::ok),
        "highlight" => req.parse::<HighlightEdit>().and_then(|e| lib.edit_highlight(e)).and_then(S::ok),
        "fill_articles" => req.parse::<Limit>().and_then(|l| lib.fill_articles(l.limit.clamp(1, 50))).and_then(S::ok),
        "today" => lib.lock_store().and_then(|s| Ok(s.today()?)).and_then(S::ok),
        _ => return None,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn finds_and_points_pictures() {
        let html = r#"<p>a</p><img src="https://e.invalid/a.jpg" srcset="https://e.invalid/a2.jpg 2x"><img alt='x' src='https://e.invalid/b.png?x=1&amp;y=2'><img src="data:image/gif;base64,AA">"#;
        assert_eq!(image_urls(html), vec!["https://e.invalid/a.jpg".to_string(), "https://e.invalid/b.png?x=1&y=2".to_string()]);

        let root = std::env::temp_dir().join(format!("wm-reader-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        let lib = Library::open(&root).unwrap_or_else(|_| std::process::abort());
        let name = lib.media.put(b"a picture", "jpg").unwrap_or_default();
        let mut item = Item { url: "https://example.com/post".into(), text: "t".into(), article: Some(html.into()), ..Default::default() };
        let id = {
            let mut store = lib.lock_store().unwrap_or_else(|_| std::process::abort());
            let saved = store.upsert_all(std::slice::from_mut(&mut item)).unwrap_or_default();
            store.remember_url("https://e.invalid/a.jpg", &name).unwrap_or_default();
            saved.first().map(|s| s.id.clone()).unwrap_or_default()
        };
        let out = lib.article_for_reader(&id).ok().flatten().unwrap_or_default();
        assert!(out.contains(&format!("src=\"wroopmark-media:///{name}\"")), "{out}");
        assert!(out.contains("src='https://e.invalid/b.png?x=1&amp;y=2'"), "{out}");
        assert!(!out.contains("srcset"), "{out}");
        lib.shutdown();
        let _ = std::fs::remove_dir_all(&root);
    }
    #[test]
    fn highlights_edit_and_sync() {
        let root = std::env::temp_dir().join(format!("wm-hl-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        let shared = root.join("shared");
        let a = Library::open(&root.join("a")).unwrap_or_else(|_| std::process::abort());
        let b = Library::open(&root.join("b")).unwrap_or_else(|_| std::process::abort());
        let call = |lib: &Arc<Library>, req: Value| -> Value {
            let r = handle_value(lib, req);
            assert_eq!(r.get("ok"), Some(&json!(true)), "{r}");
            r.get("data").cloned().unwrap_or(Value::Null)
        };
        call(&a, json!({"cmd": "import_items", "items": [{"platform": "web", "url": "https://example.com/h", "text": "bir iki üç dört"}]}));
        let id = item_id_for_url("https://example.com/h").1;
        call(&a, json!({"cmd": "sync_enable", "dir": shared}));
        call(&b, json!({"cmd": "sync_enable", "dir": shared}));

        let list = call(&a, json!({"cmd": "highlight", "id": id, "quote": "iki üç", "prefix": "bir "}));
        let hid = list.pointer("/0/id").and_then(Value::as_str).unwrap_or_default().to_string();
        assert_eq!(list.pointer("/0/color"), Some(&json!("yellow")));
        call(&a, json!({"cmd": "highlight", "id": id, "hid": hid, "note": "önemli"}));
        assert_eq!(call(&a, json!({"cmd": "search", "q": "önemli"})).pointer("/total"), Some(&json!(1)));
        assert_eq!(call(&a, json!({"cmd": "search", "q": "has:highlight"})).pointer("/total"), Some(&json!(1)));
        call(&a, json!({"cmd": "sync_now"}));
        call(&b, json!({"cmd": "sync_now"}));
        let got = call(&b, json!({"cmd": "highlights", "id": id}));
        assert_eq!(got.pointer("/0/quote"), Some(&json!("iki üç")), "{got}");
        assert_eq!(got.pointer("/0/note"), Some(&json!("önemli")));
        assert_eq!(call(&b, json!({"cmd": "search", "q": "önemli"})).pointer("/total"), Some(&json!(1)));
        assert_eq!(call(&b, json!({"cmd": "search", "q": "has:highlight"})).pointer("/total"), Some(&json!(1)));

        // Removed on B, gone on A.
        call(&b, json!({"cmd": "highlight", "id": id, "hid": hid, "delete": true}));
        call(&b, json!({"cmd": "sync_now"}));
        call(&a, json!({"cmd": "sync_now"}));
        assert_eq!(call(&a, json!({"cmd": "highlights", "id": id})), json!([]));
        assert_eq!(call(&a, json!({"cmd": "search", "q": "has:highlight"})).pointer("/total"), Some(&json!(0)));
        a.shutdown();
        b.shutdown();
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn today_finds_past_years_and_rediscover() {
        let root = std::env::temp_dir().join(format!("wm-today-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        let lib = Library::open(&root).unwrap_or_else(|_| std::process::abort());
        let call = |req: Value| -> Value {
            let r = handle_value(&lib, req);
            assert_eq!(r.get("ok"), Some(&json!(true)), "{r}");
            r.get("data").cloned().unwrap_or(Value::Null)
        };
        let last_year_today = chrono::Local::now()
            .date_naive()
            .checked_sub_months(chrono::Months::new(12))
            .and_then(|d| d.and_hms_opt(12, 0, 0))
            .and_then(|dt| dt.and_local_timezone(chrono::Local).earliest())
            .map(|dt| dt.timestamp())
            .unwrap_or_else(|| crate::text::now() - 365 * 86_400);
        let items: Vec<Value> = (0..7)
            .map(|i| {
                let saved_at = if i == 0 { last_year_today } else { crate::text::now() - (i + 10) * 86_400 };
                json!({
                    "platform": "web",
                    "url": format!("https://example.com/today/{i}"),
                    "text": format!("kayıt {i}"),
                    "saved_at": saved_at,
                })
            })
            .collect();
        call(json!({"cmd": "import_items", "items": items}));
        let res = call(json!({"cmd": "today"}));
        let on_this_day = res.pointer("/on_this_day").and_then(Value::as_array).map(Vec::len).unwrap_or(0);
        let rediscover = res.pointer("/rediscover").and_then(Value::as_array).map(Vec::len).unwrap_or(0);
        assert_eq!(on_this_day, 1, "{res}");
        assert_eq!(rediscover, 5, "{res}");
        assert_eq!(res.pointer("/total"), Some(&json!(6)));
        lib.shutdown();
        let _ = std::fs::remove_dir_all(&root);
    }
}
