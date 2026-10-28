//! X/Twitter web GraphQL → [`Item`].
//!
//! The extensions forward the JSON x.com's own web client receives
//! (`Bookmarks`, `TweetDetail`, timelines). Field names drift between X
//! releases, so every lookup tolerates the old and new shapes, and the
//! timeline walker finds tweets by structure instead of fixed paths.

use serde_json::Value;

use crate::model::{Item, Media, MediaKind, Platform};
use crate::text::tidy;

fn s(v: &Value, path: &[&str]) -> Option<String> {
    let mut cur = v;
    for key in path {
        cur = cur.get(key)?;
    }
    cur.as_str().map(str::to_string)
}

fn u(v: &Value, path: &[&str]) -> Option<u32> {
    let mut cur = v;
    for key in path {
        cur = cur.get(key)?;
    }
    cur.as_u64().and_then(|n| u32::try_from(n).ok())
}

/// Unwraps `TweetWithVisibilityResults` and similar envelopes.
fn unwrap_tweet(result: &Value) -> Option<&Value> {
    match result.get("__typename").and_then(Value::as_str) {
        Some("TweetTombstone") | Some("TweetUnavailable") => None,
        _ if result.get("legacy").is_some() => Some(result),
        _ => result.get("tweet").and_then(unwrap_tweet),
    }
}

/// `Wed Oct 10 20:19:24 +0000 2018`
fn parse_created(s: &str) -> Option<i64> {
    chrono::DateTime::parse_from_str(s, "%a %b %d %H:%M:%S %z %Y").ok().map(|d| d.timestamp())
}

fn parse_media(entry: &Value) -> Option<Media> {
    let thumb = s(entry, &["media_url_https"])?;
    let kind = match entry.get("type").and_then(Value::as_str) {
        Some("video") => MediaKind::Video,
        Some("animated_gif") => MediaKind::Gif,
        _ => MediaKind::Image,
    };
    let (width, height) = (
        u(entry, &["original_info", "width"]).or_else(|| u(entry, &["sizes", "large", "w"])),
        u(entry, &["original_info", "height"]).or_else(|| u(entry, &["sizes", "large", "h"])),
    );
    let alt = s(entry, &["ext_alt_text"]);
    if kind == MediaKind::Image {
        return Some(Media { kind, url: format!("{thumb}?name=large"), thumb_url: None, file: None, video_file: None, width, height, alt });
    }
    let best = entry
        .pointer("/video_info/variants")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter(|v| v.get("content_type").and_then(Value::as_str) == Some("video/mp4"))
        .max_by_key(|v| v.get("bitrate").and_then(Value::as_u64).unwrap_or(0))
        .and_then(|v| s(v, &["url"]))?;
    Some(Media { kind, url: best, thumb_url: Some(thumb), file: None, video_file: None, width, height, alt })
}

/// One tweet `result` object → item (quotes parsed one level deep).
pub fn parse_tweet(result: &Value) -> Option<Item> {
    parse_tweet_depth(result, 0)
}

fn parse_tweet_depth(result: &Value, depth: u8) -> Option<Item> {
    let t = unwrap_tweet(result)?;
    let legacy = t.get("legacy")?;
    // A bookmarked retweet means the original tweet.
    if let Some(rt) = legacy.pointer("/retweeted_status_result/result").and_then(|r| parse_tweet_depth(r, depth)) {
        return Some(rt);
    }
    let id = s(t, &["rest_id"]).or_else(|| s(legacy, &["id_str"]))?;

    let user = t.pointer("/core/user_results/result");
    let pick = |new: &[&str], old: &[&str]| user.and_then(|u| s(u, new).or_else(|| s(u, old)));
    let handle = pick(&["core", "screen_name"], &["legacy", "screen_name"]);
    let name = pick(&["core", "name"], &["legacy", "name"]);
    let avatar = pick(&["avatar", "image_url"], &["legacy", "profile_image_url_https"]);

    let note = t.pointer("/note_tweet/note_tweet_results/result");
    let mut text = note.and_then(|n| s(n, &["text"])).or_else(|| s(legacy, &["full_text"])).unwrap_or_default();

    // t.co → real URLs, both in the text and as the outbound link list.
    let mut links: Vec<String> = vec![];
    let url_entities = legacy
        .pointer("/entities/urls")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .chain(note.and_then(|n| n.pointer("/entity_set/urls")).and_then(Value::as_array).into_iter().flatten());
    for e in url_entities {
        let (Some(short), Some(long)) = (s(e, &["url"]), s(e, &["expanded_url"])) else { continue };
        text = text.replace(&short, &long);
        if !links.contains(&long) {
            links.push(long);
        }
    }

    let media_entries = legacy
        .pointer("/extended_entities/media")
        .or_else(|| legacy.pointer("/entities/media"))
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    for e in &media_entries {
        if let Some(short) = s(e, &["url"]) {
            text = text.replace(&short, "");
        }
    }
    let media: Vec<Media> = media_entries.iter().filter_map(parse_media).collect();

    // The quoted tweet's permalink sits at the end of the text; it is shown
    // as the quote instead.
    let quote = if depth == 0 { t.pointer("/quoted_status_result/result").and_then(|q| parse_tweet_depth(q, 1)).map(Box::new) } else { None };
    if let Some(q) = &quote {
        links.retain(|l| !l.contains(&format!("/status/{}", q.id.trim_start_matches("x:"))));
    }

    let handle_for_url = handle.clone().unwrap_or_else(|| "i".into());
    Some(Item {
        id: format!("x:{id}"),
        platform: Platform::X,
        url: format!("https://x.com/{handle_for_url}/status/{id}"),
        author_handle: handle,
        author_name: name,
        author_avatar: avatar,
        title: None,
        text: tidy(&text.replace("&amp;", "&").replace("&lt;", "<").replace("&gt;", ">")),
        extra: None,
        ocr: None,
        created_at: s(legacy, &["created_at"]).as_deref().and_then(parse_created),
        saved_at: 0,
        media,
        links,
        quote,
        tags: vec![],
        note: None,
        raw: (depth == 0).then(|| t.clone()),
    })
}

/// Bookmark entries carry a `sortIndex` minted when the bookmark was made:
/// a snowflake (milliseconds << 22) but counted from its own epoch, not
/// Twitter's. The epoch was derived from a bookmark whose time is known
/// (captured live by CreateBookmark) and checked against 842 real
/// bookmarks: none decodes to before its tweet was posted.
const BOOKMARK_EPOCH_MS: u64 = 1_344_864_594_019;

/// The real "saved at" time of a bookmark entry. Only trusted when it is
/// not just the tweet id and lands between the tweet's post time and now.
pub(crate) fn bookmark_time(sort: &str, item: &Item) -> Option<i64> {
    bookmark_time_at(sort, item, crate::text::now())
}

/// [`bookmark_time`] with the current time given (tests).
fn bookmark_time_at(sort: &str, item: &Item, now: i64) -> Option<i64> {
    if item.id.strip_prefix("x:") == Some(sort) {
        return None;
    }
    let n: u64 = sort.parse().ok()?;
    let secs = i64::try_from(((n >> 22) + BOOKMARK_EPOCH_MS) / 1000).ok()?;
    let after_post = item.created_at.is_none_or(|c| secs >= c - 60);
    (after_post && secs <= now + 3600).then_some(secs)
}

/// Every top-level tweet in a GraphQL timeline response, in timeline order.
/// Tweets are found under `itemContent.tweet_results.result`, which covers
/// plain entries, conversation modules and the bookmark timeline alike;
/// quoted tweets live elsewhere and stay nested in their parent.
pub fn parse_timeline(v: &Value) -> Vec<Item> {
    fn walk(v: &Value, sort: Option<&str>, out: &mut Vec<Item>) {
        match v {
            Value::Object(map) => {
                // Seen as a string so far; accept a number too.
                let own = map.get("sortIndex").and_then(|v| v.as_str().map(str::to_string).or_else(|| v.as_u64().map(|n| n.to_string())));
                let sort = own.as_deref().or(sort);
                if let Some(result) = map.get("itemContent").and_then(|c| c.pointer("/tweet_results/result")) {
                    if let Some(mut item) = parse_tweet(result)
                        && !out.iter().any(|o| o.id == item.id)
                    {
                        item.saved_at = sort.and_then(|s| bookmark_time(s, &item)).unwrap_or(0);
                        // Kept with the raw tweet so the ordering rule can be
                        // checked against what X really sends.
                        if let (Some(s), Some(Value::Object(raw))) = (sort, item.raw.as_mut()) {
                            raw.insert("__sortIndex".into(), Value::String(s.to_string()));
                        }
                        out.push(item);
                    }
                    return;
                }
                map.values().for_each(|c| walk(c, sort, out));
            }
            Value::Array(arr) => arr.iter().for_each(|c| walk(c, sort, out)),
            _ => {}
        }
    }
    let mut out = vec![];
    walk(v, None, &mut out);
    // A bare tweet result (e.g. `TweetResultByRestId`).
    if out.is_empty() {
        if let Some(r) = v.pointer("/data/tweetResult/result").or_else(|| v.pointer("/data/tweet_result/result")) {
            out.extend(parse_tweet(r));
        } else if v.get("legacy").is_some() || v.get("tweet").is_some() {
            out.extend(parse_tweet(v));
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn tweet(id: &str, text: &str) -> Value {
        json!({
            "__typename": "Tweet",
            "rest_id": id,
            "core": { "user_results": { "result": {
                "core": { "screen_name": "jack", "name": "Jack" },
                "avatar": { "image_url": "https://pbs.twimg.com/profile_images/1/a_normal.jpg" }
            }}},
            "legacy": {
                "full_text": text,
                "created_at": "Wed Oct 10 20:19:24 +0000 2018",
                "entities": { "urls": [{ "url": "https://t.co/L", "expanded_url": "https://github.com/x/y" }] },
                "extended_entities": { "media": [
                    { "type": "photo", "url": "https://t.co/M", "media_url_https": "https://pbs.twimg.com/media/A.jpg",
                      "original_info": { "width": 1200, "height": 800 } },
                    { "type": "video", "url": "https://t.co/M", "media_url_https": "https://pbs.twimg.com/thumb/V.jpg",
                      "video_info": { "variants": [
                        { "content_type": "application/x-mpegURL", "url": "https://v/pl.m3u8" },
                        { "content_type": "video/mp4", "bitrate": 832000, "url": "https://v/low.mp4" },
                        { "content_type": "video/mp4", "bitrate": 2176000, "url": "https://v/high.mp4" }
                      ]}}
                ]}
            }
        })
    }

    #[test]
    fn parses_bookmark_timeline() {
        let mut quoted = tweet("9", "alıntı");
        quoted["core"]["user_results"]["result"]["core"]["screen_name"] = json!("dhh");
        let mut main = tweet("1", "bak https://t.co/L güzel &amp; hızlı https://t.co/M");
        main["quoted_status_result"] = json!({ "result": quoted });
        let page = json!({ "data": { "bookmark_timeline_v2": { "timeline": { "instructions": [{
            "type": "TimelineAddEntries",
            "entries": [
                { "entryId": "tweet-1", "sortIndex": "1880256981948235488", "content": { "itemContent": { "tweet_results": { "result":
                    { "__typename": "TweetWithVisibilityResults", "tweet": main } } } } },
                { "entryId": "tweet-2", "content": { "itemContent": { "tweet_results": { "result": tweet("2", "ikinci") } } } },
                { "entryId": "cursor-bottom-1", "content": { "value": "abc" } }
            ]
        }]}}}});

        let items = parse_timeline(&page);
        assert_eq!(items.len(), 2);
        let a = &items[0];
        assert_eq!(a.id, "x:1");
        assert_eq!(a.url, "https://x.com/jack/status/1");
        assert_eq!(a.text, "bak https://github.com/x/y güzel & hızlı");
        assert_eq!(a.links, vec!["https://github.com/x/y"]);
        assert_eq!(a.created_at, Some(1539202764));
        // The live-captured bookmark: 2026-10-28 01:59:52 UTC. A time after
        // "now" is not trusted, so the check uses a fixed clock.
        let probe = Item { id: "x:1".into(), created_at: a.created_at, ..Default::default() };
        assert_eq!(bookmark_time_at("1880256981948235488", &probe, 1_793_200_000), Some(1793152792));
        assert_eq!(bookmark_time_at("1880256981948235488", &probe, 1_700_000_000), None);
        assert_eq!(a.saved_at, bookmark_time("1880256981948235488", &probe).unwrap_or(0));
        assert_eq!(items[1].saved_at, 0); // no sortIndex: the store stamps it
        assert_eq!(a.media.len(), 2);
        assert_eq!(a.media[0].url, "https://pbs.twimg.com/media/A.jpg?name=large");
        assert_eq!(a.media[1].url, "https://v/high.mp4");
        assert_eq!(a.media[1].thumb_url.as_deref(), Some("https://pbs.twimg.com/thumb/V.jpg"));
        let q = a.quote.as_ref().unwrap();
        assert_eq!((q.id.as_str(), q.author_handle.as_deref()), ("x:9", Some("dhh")));
        assert!(q.raw.is_none() && a.raw.is_some());
    }
}
