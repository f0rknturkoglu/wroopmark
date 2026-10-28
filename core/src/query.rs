//! Search syntax.
//!
//! ```text
//! rust async  "tam ifade"  -kelime
//! tag:dev  -tag:okundu  is:untagged  is:tagged
//! from:@jack  @jack  platform:x  has:image|video|media|link|note|ocr|quote
//! is:reviewed  (kept in the clean-up view)
//! before:2025-06  after:2024  (post date, falls back to save date)
//! savedbefore:2026-10  savedafter:2026-01  (when it was saved)
//! ```
//!
//! Every filter can be negated with a leading `-` (`-from:@jack`, `-@jack`,
//! `-platform:tiktok`, `-has:video`, `-is:untagged`, `-is:reviewed`).
//! Sorting is not part of the text; see [`Sort`].

use chrono::NaiveDate;

use crate::model::Platform;
use crate::text::{fold, tokens};

#[derive(Debug, Default, PartialEq)]
pub struct Query {
    /// Folded words (prefix-matched) and phrases (exact).
    pub words: Vec<String>,
    pub phrases: Vec<String>,
    pub not_words: Vec<String>,
    pub tags: Vec<String>,
    pub not_tags: Vec<String>,
    pub authors: Vec<String>,
    pub not_authors: Vec<String>,
    pub platforms: Vec<Platform>,
    pub not_platforms: Vec<Platform>,
    pub has: Vec<Has>,
    pub not_has: Vec<Has>,
    /// `is:untagged` → Some(false), `is:tagged` / `-is:untagged` → Some(true).
    pub tagged: Option<bool>,
    /// `is:reviewed` → Some(true), `-is:reviewed` → Some(false).
    pub reviewed: Option<bool>,
    pub before: Option<i64>,
    pub after: Option<i64>,
    pub saved_before: Option<i64>,
    pub saved_after: Option<i64>,
}

/// Result order. `Default` is relevance when there is text, else newest
/// saved first.
#[derive(Debug, Clone, Copy, Default, PartialEq)]
pub enum Sort {
    #[default]
    Default,
    SavedNewest,
    SavedOldest,
    PostedNewest,
    PostedOldest,
    Author,
    /// A fixed shuffle per seed, so paging through it stays consistent.
    Random(u32),
}

impl Sort {
    /// `saved`, `saved_asc`, `posted`, `posted_asc`, `author`, `random:<seed>`;
    /// anything else is the default.
    pub fn parse(s: &str) -> Self {
        match s.trim() {
            "saved" => Sort::SavedNewest,
            "saved_asc" => Sort::SavedOldest,
            "posted" => Sort::PostedNewest,
            "posted_asc" => Sort::PostedOldest,
            "author" => Sort::Author,
            s => match s.strip_prefix("random:").and_then(|n| n.parse().ok()) {
                Some(seed) => Sort::Random(seed),
                None if s == "random" => Sort::Random(1),
                None => Sort::Default,
            },
        }
    }

    /// ORDER BY terms over `items i`; `None` keeps the search's own order.
    pub fn sql(self) -> Option<String> {
        let posted = "coalesce(i.created_at, i.saved_at)";
        Some(match self {
            Sort::Default => return None,
            Sort::SavedNewest => "i.saved_at DESC, i.pk DESC".into(),
            Sort::SavedOldest => "i.saved_at ASC, i.pk ASC".into(),
            Sort::PostedNewest => format!("{posted} DESC, i.pk DESC"),
            Sort::PostedOldest => format!("{posted} ASC, i.pk ASC"),
            Sort::Author => {
                "coalesce(i.author_handle, i.author_name) IS NULL, lower(coalesce(i.author_handle, i.author_name)), i.saved_at DESC".into()
            }
            // A multiplicative hash of pk + seed; small enough not to overflow.
            Sort::Random(seed) => format!("((i.pk + {}) * 2654435761) % 4294967291, i.pk", seed % 1_000_000),
        })
    }
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Has {
    Image,
    Video,
    Media,
    Link,
    Note,
    /// Text was read from its pictures.
    Ocr,
    Quote,
}

/// Splits on whitespace, keeping `"quoted phrases"` (and `key:"quoted"`) whole.
fn split(input: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut cur = String::new();
    let mut quoted = false;
    for c in input.chars() {
        match c {
            '"' => {
                quoted = !quoted;
                cur.push(c);
            }
            c if c.is_whitespace() && !quoted => {
                if !cur.is_empty() {
                    out.push(std::mem::take(&mut cur));
                }
            }
            c => cur.push(c),
        }
    }
    if !cur.is_empty() {
        out.push(cur);
    }
    out
}

/// `2025`, `2025-06`, `2025-06-14` → unix seconds at the start (or, with
/// `end`, the end) of that period.
fn parse_date(s: &str, end: bool) -> Option<i64> {
    let parts: Vec<&str> = s.split('-').collect();
    let y: i32 = parts.first()?.parse().ok()?;
    let m: Option<u32> = parts.get(1).and_then(|p| p.parse().ok());
    let d: Option<u32> = parts.get(2).and_then(|p| p.parse().ok());
    let start = NaiveDate::from_ymd_opt(y, m.unwrap_or(1), d.unwrap_or(1))?;
    let date = if !end {
        start
    } else if d.is_some() {
        start.succ_opt()?
    } else if let Some(m) = m {
        if m == 12 { NaiveDate::from_ymd_opt(y + 1, 1, 1)? } else { NaiveDate::from_ymd_opt(y, m + 1, 1)? }
    } else {
        NaiveDate::from_ymd_opt(y + 1, 1, 1)?
    };
    Some(date.and_hms_opt(0, 0, 0)?.and_utc().timestamp())
}

pub fn tag_key(tag: &str) -> String {
    let t = tag.trim().trim_start_matches('#');
    t.split('/').map(|p| fold(p.trim())).filter(|p| !p.is_empty()).collect::<Vec<_>>().join("/")
}

impl Query {
    pub fn parse(input: &str) -> Self {
        let mut q = Query::default();
        for raw in split(input) {
            let (neg, tok) = match raw.strip_prefix('-') {
                Some(rest) if !rest.is_empty() => (true, rest),
                _ => (false, raw.as_str()),
            };
            let unquote = |s: &str| s.trim_matches('"').to_string();
            if let Some((key, val)) = tok.split_once(':').filter(|(k, v)| !k.is_empty() && !v.is_empty() && !k.starts_with('"')) {
                let val = unquote(val);
                let handled = match key.to_ascii_lowercase().as_str() {
                    "tag" | "t" => {
                        let t = tag_key(&val);
                        if neg {
                            q.not_tags.push(t)
                        } else {
                            q.tags.push(t)
                        }
                        true
                    }
                    "from" | "by" | "@" => {
                        let a = val.trim_start_matches('@').to_ascii_lowercase();
                        if neg {
                            q.not_authors.push(a)
                        } else {
                            q.authors.push(a)
                        }
                        true
                    }
                    "platform" | "on" | "in" => match Platform::parse(&val) {
                        Some(p) => {
                            if neg {
                                q.not_platforms.push(p)
                            } else {
                                q.platforms.push(p)
                            }
                            true
                        }
                        None => false,
                    },
                    "has" => {
                        let h = match val.to_ascii_lowercase().as_str() {
                            "image" | "img" | "photo" | "gorsel" => Some(Has::Image),
                            "video" => Some(Has::Video),
                            "media" | "medya" => Some(Has::Media),
                            "link" | "links" => Some(Has::Link),
                            "note" | "not" => Some(Has::Note),
                            "ocr" | "yazi" => Some(Has::Ocr),
                            "quote" | "alinti" => Some(Has::Quote),
                            _ => None,
                        };
                        h.map(|h| if neg { q.not_has.push(h) } else { q.has.push(h) }).is_some()
                    }
                    "is" => match val.to_ascii_lowercase().as_str() {
                        "untagged" => {
                            q.tagged = Some(neg);
                            true
                        }
                        "tagged" => {
                            q.tagged = Some(!neg);
                            true
                        }
                        "reviewed" => {
                            q.reviewed = Some(!neg);
                            true
                        }
                        _ => false,
                    },
                    "savedbefore" | "saved-before" => parse_date(&val, false).map(|t| q.saved_before = Some(t)).is_some(),
                    "savedafter" | "saved-after" => parse_date(&val, true).map(|t| q.saved_after = Some(t)).is_some(),
                    "before" | "until" => parse_date(&val, false).map(|t| q.before = Some(t)).is_some(),
                    "after" | "since" => parse_date(&val, true).map(|t| q.after = Some(t)).is_some(),
                    _ => false,
                };
                if handled {
                    continue;
                }
            }
            // A bare `@handle` is an author filter.
            if let Some(h) = tok.strip_prefix('@').filter(|h| !h.is_empty()) {
                let a = h.to_ascii_lowercase();
                if neg {
                    q.not_authors.push(a)
                } else {
                    q.authors.push(a)
                }
                continue;
            }
            let folded = fold(&unquote(tok));
            let toks = tokens(&folded);
            if toks.is_empty() {
                continue;
            }
            let joined = toks.join(" ");
            if neg {
                q.not_words.push(joined);
            } else if tok.starts_with('"') || toks.len() > 1 {
                q.phrases.push(joined);
            } else {
                q.words.push(joined);
            }
        }
        q
    }

    pub fn has_text(&self) -> bool {
        !self.words.is_empty() || !self.phrases.is_empty()
    }

    /// FTS5 MATCH expression for the positive terms. Every token is quoted,
    /// so user input can never inject FTS operators.
    pub fn fts_positive(&self) -> Option<String> {
        let mut parts: Vec<String> = self.words.iter().map(|w| format!("\"{w}\"*")).collect();
        parts.extend(self.phrases.iter().map(|p| format!("\"{p}\"")));
        (!parts.is_empty()).then(|| parts.join(" "))
    }

    /// MATCH expression for the negated words, OR-ed.
    pub fn fts_negative(&self) -> Option<String> {
        let parts: Vec<String> = self.not_words.iter().map(|w| format!("\"{w}\"")).collect();
        (!parts.is_empty()).then(|| parts.join(" OR "))
    }

    /// True when the query filters by what items are (tags, author, date…),
    /// not just by text. Links then only count through matching items.
    pub fn filters_items(&self) -> bool {
        !self.tags.is_empty()
            || !self.not_tags.is_empty()
            || !self.authors.is_empty()
            || !self.not_authors.is_empty()
            || !self.platforms.is_empty()
            || !self.not_platforms.is_empty()
            || !self.has.is_empty()
            || !self.not_has.is_empty()
            || self.tagged.is_some()
            || self.reviewed.is_some()
            || self.before.is_some()
            || self.after.is_some()
            || self.saved_before.is_some()
            || self.saved_after.is_some()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_everything() {
        let q = Query::parse(r#"Rust "Async Böök" -okundu tag:Dev/Rust -tag:eski from:@Jack platform:twitter has:image after:2024 is:untagged @dhh"#);
        assert_eq!(q.words, vec!["rust"]);
        assert_eq!(q.phrases, vec!["async book"]);
        assert_eq!(q.not_words, vec!["okundu"]);
        assert_eq!(q.tags, vec!["dev/rust"]);
        assert_eq!(q.not_tags, vec!["eski"]);
        assert_eq!(q.authors, vec!["jack", "dhh"]);
        assert_eq!(q.platforms, vec![Platform::X]);
        assert_eq!(q.has, vec![Has::Image]);
        assert_eq!(q.tagged, Some(false));
        assert_eq!(q.after, Some(1735689600)); // 2025-01-01: "after 2024" means after the year ends
        assert_eq!(q.fts_positive().as_deref(), Some(r#""rust"* "async book""#));
    }

    #[test]
    fn every_filter_negates() {
        let q = Query::parse("-from:@Jack -@dhh -platform:tiktok -has:video -is:untagged");
        assert_eq!(q.not_authors, vec!["jack", "dhh"]);
        assert!(q.authors.is_empty() && q.not_words.is_empty());
        assert_eq!(q.not_platforms, vec![Platform::Tiktok]);
        assert_eq!(q.not_has, vec![Has::Video]);
        assert_eq!(q.tagged, Some(true));
        assert_eq!(Query::parse("is:tagged").tagged, Some(true));
        assert!(q.filters_items());
        assert!(!Query::parse("rust -go").filters_items());
    }

    #[test]
    fn review_saved_dates_and_sort() {
        let q = Query::parse("-is:reviewed savedafter:2026-01 savedbefore:2026-10 has:ocr -has:quote");
        assert_eq!(q.reviewed, Some(false));
        assert_eq!(q.saved_after, parse_date("2026-01", true));
        assert_eq!(q.saved_before, parse_date("2026-10", false));
        assert_eq!((q.has.as_slice(), q.not_has.as_slice()), (&[Has::Ocr][..], &[Has::Quote][..]));
        assert_eq!(Sort::parse("random:42"), Sort::Random(42));
        assert_eq!(Sort::parse("posted_asc"), Sort::PostedOldest);
        assert_eq!(Sort::parse("nonsense"), Sort::Default);
        assert!(Sort::Default.sql().is_none());
    }

    #[test]
    fn unknown_keys_are_words() {
        let q = Query::parse("http://x.com foo:bar");
        assert_eq!(q.phrases, vec!["http x com", "foo bar"]);
    }

    #[test]
    fn quotes_cannot_inject() {
        let q = Query::parse(r#"a" OR "b NEAR(x"#);
        let m = q.fts_positive().unwrap();
        assert!(!m.contains("NEAR("));
    }

    #[test]
    fn dates() {
        assert_eq!(parse_date("2025-06", false), Some(1748736000));
        assert_eq!(parse_date("2025-12", true), Some(1767225600));
        assert_eq!(parse_date("2025-06-14", true), Some(1749945600));
    }
}
