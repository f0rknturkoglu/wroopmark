//! Text helpers: search folding, URL normalization, deterministic ids.

use std::borrow::Cow;
use std::sync::LazyLock;

use regex::Regex;
use unicode_normalization::UnicodeNormalization;
use unicode_normalization::char::is_combining_mark;
use url::Url;

use crate::model::Platform;

/// Folds text for indexing and querying. Both sides go through this, so the
/// FTS tokenizer only ever sees lowercase ASCII-ish words.
///
/// SQLite's own case folding gets Turkish wrong (`İ` → `i̇`, `ı` untouched),
/// so the dotted/dotless i family collapses to `i` first, then diacritics go
/// (`ş→s`, `ğ→g`, `ö→o`…). "istanbul" == "İSTANBUL" == "ıstanbul".
pub fn fold(s: &str) -> String {
    if s.is_ascii() {
        return s.to_ascii_lowercase();
    }
    s.chars()
        .map(|c| match c {
            'İ' | 'I' | 'ı' => 'i',
            c => c,
        })
        .nfkd()
        .filter(|c| !is_combining_mark(*c))
        .flat_map(char::to_lowercase)
        .collect()
}

/// Splits folded text the way FTS5's unicode61 tokenizer does (alphanumerics).
pub fn tokens(folded: &str) -> Vec<&str> {
    folded.split(|c: char| !c.is_alphanumeric()).filter(|t| !t.is_empty()).collect()
}

static URL_RE: LazyLock<Option<Regex>> = LazyLock::new(|| Regex::new(r#"https?://[^\s<>"'`\u{2026}]+"#).ok());

/// URLs mentioned in free text, with trailing punctuation trimmed.
pub fn extract_urls(text: &str) -> Vec<String> {
    let Some(re) = URL_RE.as_ref() else {
        return Vec::new();
    };
    let mut out: Vec<String> = Vec::new();
    for m in re.find_iter(text) {
        let mut u = m.as_str();
        while let Some(last) = u.chars().last() {
            let unbalanced_paren = last == ')' && u.matches('(').count() < u.matches(')').count();
            if ".,;:!?'\"]}".contains(last) || unbalanced_paren {
                u = u.strip_suffix(last).unwrap_or("");
            } else {
                break;
            }
        }
        if !u.is_empty() && !out.iter().any(|x| x == u) {
            out.push(u.to_string());
        }
    }
    out
}

/// Query parameters that only track the click, never change the content.
fn is_tracking_param(key: &str, is_x: bool) -> bool {
    const TRACKING_KEYS: [&str; 23] = [
        "fbclid",
        "gclid",
        "dclid",
        "msclkid",
        "igshid",
        "igsh",
        "mc_cid",
        "mc_eid",
        "_hsenc",
        "_hsmi",
        "ref_src",
        "ref_url",
        "yclid",
        "twclid",
        "si",
        "mibextid",
        "rdid",
        "share_id",
        "_branch_match_id",
        "is_from_webapp",
        "sender_device",
        "_r",
        "_t",
    ];
    key.get(..4).is_some_and(|p| p.eq_ignore_ascii_case("utm_"))
        || TRACKING_KEYS.iter().any(|k| key.eq_ignore_ascii_case(k))
        // x.com/…?s=20&t=… share suffixes
        || (is_x && (key.eq_ignore_ascii_case("s") || key.eq_ignore_ascii_case("t") || key.eq_ignore_ascii_case("ref")))
}

fn canon_host(h: &str) -> Cow<'_, str> {
    let lower: Cow<'_, str> = if h.bytes().any(|b| b.is_ascii_uppercase()) { Cow::Owned(h.to_ascii_lowercase()) } else { Cow::Borrowed(h) };
    let trimmed = lower.strip_prefix("www.").unwrap_or(&lower);
    if matches!(trimmed, "twitter.com" | "mobile.twitter.com" | "m.twitter.com" | "mobile.x.com") {
        Cow::Borrowed("x.com")
    } else {
        match lower {
            Cow::Owned(s) => {
                if let Some(rest) = s.strip_prefix("www.") {
                    Cow::Owned(rest.to_string())
                } else {
                    Cow::Owned(s)
                }
            }
            Cow::Borrowed(s) => Cow::Borrowed(s.strip_prefix("www.").unwrap_or(s)),
        }
    }
}

/// Canonical form used to deduplicate links: http(s) only, lowercase host
/// without `www.`, no fragment, no tracking parameters, no trailing slash,
/// `twitter.com` → `x.com`.
pub fn normalize_url(raw: &str) -> Option<String> {
    let mut url = Url::parse(raw.trim()).ok()?;
    if !matches!(url.scheme(), "http" | "https") {
        return None;
    }
    let is_x = {
        let raw_host = url.host_str()?;
        let target = canon_host(raw_host);
        let is_x = target == "x.com";
        if target != raw_host {
            let new_host = target.into_owned();
            url.set_host(Some(&new_host)).ok()?;
        }
        is_x
    };
    let _ = url.set_scheme("https");
    url.set_fragment(None);
    let needs_query_clean = url.query().is_some_and(|q| q.is_empty() || url.query_pairs().any(|(k, _)| is_tracking_param(&k, is_x)));
    if needs_query_clean {
        let kept: Vec<(String, String)> =
            url.query_pairs().filter(|(k, _)| !is_tracking_param(k, is_x)).map(|(k, v)| (k.into_owned(), v.into_owned())).collect();
        if kept.is_empty() {
            url.set_query(None);
        } else {
            url.query_pairs_mut().clear().extend_pairs(kept);
        }
    }
    if url.path().len() > 1 && url.path().ends_with('/') {
        let trimmed = url.path().trim_end_matches('/').to_string();
        url.set_path(&trimmed);
    }
    let bare_root = url.path() == "/" && url.query().is_none();
    let mut s: String = url.into();
    if bare_root && s.ends_with('/') {
        s.pop();
    }
    Some(s)
}

pub fn host_of(url: &str) -> String {
    Url::parse(url).ok().and_then(|u| u.host_str().map(|h| h.trim_start_matches("www.").to_string())).unwrap_or_default()
}

pub fn hash_hex(bytes: &[u8]) -> String {
    format!("{:032x}", xxhash_rust::xxh3::xxh3_128(bytes))
}

fn short_hash_hex(bytes: &[u8]) -> String {
    format!("{:016x}", (xxhash_rust::xxh3::xxh3_128(bytes) >> 64) as u64)
}

/// The numeric post id the platform uses, if the URL carries one.
fn platform_post_id(platform: Platform, url: &Url) -> Option<String> {
    let segs: Vec<&str> = url.path_segments()?.filter(|s| !s.is_empty()).collect();
    let after = |key: &str| {
        segs.iter().position(|s| *s == key).and_then(|i| segs.get(i + 1)).filter(|s| s.chars().all(|c| c.is_ascii_digit())).map(|s| s.to_string())
    };
    match platform {
        Platform::X => after("status").or_else(|| after("statuses")),
        Platform::Tiktok => after("video").or_else(|| after("photo")),
        Platform::Pinterest => after("pin"),
        Platform::Facebook => {
            let q = url.query_pairs().find(|(k, _)| k == "story_fbid" || k == "fbid" || k == "v");
            q.map(|(_, v)| v.into_owned()).or_else(|| after("posts").or_else(|| after("videos")))
        }
        Platform::Reddit => segs.iter().position(|s| *s == "comments").and_then(|i| segs.get(i + 1)).map(|s| s.to_string()),
        Platform::Youtube => {
            let q = url.query_pairs().find(|(k, _)| k == "v").map(|(_, v)| v.into_owned());
            let shorts = segs.iter().position(|s| *s == "shorts").and_then(|i| segs.get(i + 1)).map(|s| s.to_string());
            let short_domain = if url.host_str().is_some_and(|h| h.contains("youtu.be")) { segs.first().map(|s| s.to_string()) } else { None };
            q.or(shorts).or(short_domain)
        }
        Platform::Instagram => {
            segs.iter().position(|s| *s == "p" || *s == "reel" || *s == "reels").and_then(|i| segs.get(i + 1)).map(|s| s.to_string())
        }
        Platform::Github => {
            let [owner, repo, ..] = segs.as_slice() else {
                return None;
            };
            Some(format!("{owner}_{repo}"))
        }
        Platform::Hackernews => url.query_pairs().find(|(k, _)| k == "id").map(|(_, v)| v.into_owned()),
        Platform::Arxiv => segs.iter().position(|s| *s == "abs" || *s == "pdf").and_then(|i| segs.get(i + 1)).map(|s| s.to_string()),
        Platform::Web => None,
    }
}

/// Deterministic item id for a URL. Posts get the platform's own id so the
/// same post saved from a share sheet and from the extension is one item.
pub fn item_id_for_url(url: &str) -> (Platform, String) {
    let norm = normalize_url(url).unwrap_or_else(|| url.trim().to_string());
    let parsed = Url::parse(&norm).ok();
    let platform = parsed.as_ref().and_then(|u| u.host_str()).map(Platform::from_host).unwrap_or(Platform::Web);
    if let Some(id) = parsed.as_ref().and_then(|u| platform_post_id(platform, u)) {
        return (platform, format!("{}:{id}", platform.as_str()));
    }
    let tag = if platform == Platform::Web { "web" } else { platform.as_str() };
    (platform, format!("{tag}:{}", short_hash_hex(norm.as_bytes())))
}

pub fn now() -> i64 {
    chrono::Utc::now().timestamp()
}

/// Collapses whitespace runs and trims; keeps paragraph breaks.
pub fn tidy(s: &str) -> String {
    let mut out = String::with_capacity(s.len().min(4096));
    let mut first_para = true;
    for para in s.split("\n\n") {
        let mut first_word = true;
        for word in para.split_whitespace() {
            if first_word {
                if !first_para {
                    out.push_str("\n\n");
                }
                first_para = false;
                first_word = false;
            } else {
                out.push(' ');
            }
            out.push_str(word);
        }
    }
    if out.capacity() > out.len().saturating_mul(2) && out.capacity() > 1024 {
        out.shrink_to_fit();
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn folds_turkish() {
        assert_eq!(fold("İSTANBUL"), "istanbul");
        assert_eq!(fold("ıspanak IĞDIR"), "ispanak igdir");
        assert_eq!(fold("Şöyle çüğ"), "soyle cug");
        assert_eq!(fold("Café"), "cafe");
        assert_eq!(fold("Cafe\u{0301} ﬁle²"), "cafe file2");
        assert!(URL_RE.is_some());
        assert_eq!(short_hash_hex(b"hello"), &hash_hex(b"hello")[..16]);
        assert_eq!(tidy("  merhaba   dünya \n\n\n   iki   satır  "), "merhaba dünya\n\niki satır");
    }

    #[test]
    fn normalizes_urls() {
        assert_eq!(normalize_url("https://twitter.com/jack/status/20?s=20&t=abc#x").as_deref(), Some("https://x.com/jack/status/20"));
        assert_eq!(normalize_url("http://www.Example.com/a/b/?utm_source=x&id=3").as_deref(), Some("https://example.com/a/b?id=3"));
        assert_eq!(normalize_url("https://example.com/").as_deref(), Some("https://example.com"));
        assert_eq!(normalize_url("ftp://example.com"), None);
    }

    #[test]
    fn ids_are_platform_native() {
        assert_eq!(item_id_for_url("https://twitter.com/a/status/123?s=1"), (Platform::X, "x:123".into()));
        assert_eq!(item_id_for_url("https://www.tiktok.com/@u/video/7301?is_from_webapp=1"), (Platform::Tiktok, "tiktok:7301".into()));
        assert_eq!(item_id_for_url("https://tr.pinterest.com/pin/998/"), (Platform::Pinterest, "pinterest:998".into()));
        let (p, id) = item_id_for_url("https://blog.rust-lang.org/a?utm_source=x");
        assert_eq!(p, Platform::Web);
        assert_eq!(id, item_id_for_url("https://blog.rust-lang.org/a").1);
    }

    #[test]
    fn extracts_urls() {
        let t = "bak: https://a.com/x. ve (https://b.com/y) https://en.wikipedia.org/wiki/Rust_(language)!";
        assert_eq!(extract_urls(t), vec!["https://a.com/x", "https://b.com/y", "https://en.wikipedia.org/wiki/Rust_(language)"]);
    }
}
