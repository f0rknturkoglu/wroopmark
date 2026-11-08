//! Text helpers: search folding, URL normalization, deterministic ids.

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
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        match c {
            'İ' | 'I' | 'ı' => out.push('i'),
            c => out.push(c),
        }
    }
    out.nfkd().filter(|c| !is_combining_mark(*c)).flat_map(char::to_lowercase).collect()
}

/// Splits folded text the way FTS5's unicode61 tokenizer does (alphanumerics).
pub fn tokens(folded: &str) -> Vec<&str> {
    folded.split(|c: char| !c.is_alphanumeric()).filter(|t| !t.is_empty()).collect()
}

static URL_RE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r#"https?://[^\s<>"'`\u{2026}]+"#).expect("url regex"));

/// URLs mentioned in free text, with trailing punctuation trimmed.
pub fn extract_urls(text: &str) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    for m in URL_RE.find_iter(text) {
        let mut u = m.as_str();
        while let Some(last) = u.chars().last() {
            let unbalanced_paren = last == ')' && u.matches('(').count() < u.matches(')').count();
            if ".,;:!?'\"]}".contains(last) || unbalanced_paren {
                u = &u[..u.len() - last.len_utf8()];
            } else {
                break;
            }
        }
        if !out.iter().any(|x| x == u) {
            out.push(u.to_string());
        }
    }
    out
}

/// Query parameters that only track the click, never change the content.
fn is_tracking_param(key: &str, host: &str) -> bool {
    let k = key.to_ascii_lowercase();
    k.starts_with("utm_")
        || matches!(
            k.as_str(),
            "fbclid" | "gclid" | "dclid" | "msclkid" | "igshid" | "igsh" | "mc_cid" | "mc_eid" | "_hsenc"
                | "_hsmi" | "ref_src" | "ref_url" | "yclid" | "twclid" | "si" | "mibextid" | "rdid"
                | "share_id" | "_branch_match_id" | "is_from_webapp" | "sender_device" | "_r" | "_t"
        )
        // x.com/…?s=20&t=… share suffixes
        || (host == "x.com" && matches!(k.as_str(), "s" | "t" | "ref"))
}

/// Canonical form used to deduplicate links: http(s) only, lowercase host
/// without `www.`, no fragment, no tracking parameters, no trailing slash,
/// `twitter.com` → `x.com`.
pub fn normalize_url(raw: &str) -> Option<String> {
    let mut url = Url::parse(raw.trim()).ok()?;
    if !matches!(url.scheme(), "http" | "https") {
        return None;
    }
    let host = url.host_str()?.to_ascii_lowercase();
    let mut host = host.strip_prefix("www.").unwrap_or(&host).to_string();
    if matches!(host.as_str(), "twitter.com" | "mobile.twitter.com" | "m.twitter.com" | "mobile.x.com") {
        host = "x.com".into();
    }
    url.set_host(Some(&host)).ok()?;
    let _ = url.set_scheme("https");
    url.set_fragment(None);
    let kept: Vec<(String, String)> =
        url.query_pairs().filter(|(k, _)| !is_tracking_param(k, &host)).map(|(k, v)| (k.into_owned(), v.into_owned())).collect();
    if kept.is_empty() {
        url.set_query(None);
    } else {
        url.query_pairs_mut().clear().extend_pairs(kept);
    }
    let path = url.path().to_string();
    if path.len() > 1 && path.ends_with('/') {
        url.set_path(path.trim_end_matches('/'));
    }
    let mut s = url.to_string();
    if s.ends_with('/') && url.path() == "/" && url.query().is_none() {
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
        Platform::Reddit => {
            segs.iter().position(|s| *s == "comments").and_then(|i| segs.get(i + 1)).map(|s| s.to_string())
        }
        Platform::Youtube => {
            let q = url.query_pairs().find(|(k, _)| k == "v").map(|(_, v)| v.into_owned());
            let shorts = segs.iter().position(|s| *s == "shorts").and_then(|i| segs.get(i + 1)).map(|s| s.to_string());
            let short_domain = if url.host_str().is_some_and(|h| h.contains("youtu.be")) {
                segs.first().map(|s| s.to_string())
            } else {
                None
            };
            q.or(shorts).or(short_domain)
        }
        Platform::Instagram => {
            segs.iter().position(|s| *s == "p" || *s == "reel" || *s == "reels").and_then(|i| segs.get(i + 1)).map(|s| s.to_string())
        }
        Platform::Github => {
            if segs.len() >= 2 {
                Some(format!("{}_{}", segs[0], segs[1]))
            } else {
                None
            }
        }
        Platform::Hackernews => {
            url.query_pairs().find(|(k, _)| k == "id").map(|(_, v)| v.into_owned())
        }
        Platform::Arxiv => {
            segs.iter().position(|s| *s == "abs" || *s == "pdf").and_then(|i| segs.get(i + 1)).map(|s| s.to_string())
        }
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
    (platform, format!("{tag}:{}", &hash_hex(norm.as_bytes())[..16]))
}

pub fn now() -> i64 {
    chrono::Utc::now().timestamp()
}

/// Collapses whitespace runs and trims; keeps paragraph breaks.
pub fn tidy(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for (i, para) in s.split("\n\n").map(|p| p.split_whitespace().collect::<Vec<_>>().join(" ")).filter(|p| !p.is_empty()).enumerate() {
        if i > 0 {
            out.push_str("\n\n");
        }
        out.push_str(&para);
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
