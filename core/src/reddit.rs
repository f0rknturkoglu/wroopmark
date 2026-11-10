//! Reddit listing JSON → [`Item`].
//!
//! The extension reads `/user/<name>/saved.json` with the user's own session
//! (the same JSON reddit.com serves to anyone signed in) and hands the pages
//! over. Posts (`t3`) and saved comments (`t1`) both become items.

use serde_json::Value;

use crate::model::{Item, Media, MediaKind, Platform};
use crate::text::{extract_urls, tidy};

fn s(v: &Value, ptr: &str) -> Option<String> {
    v.pointer(ptr).and_then(Value::as_str).filter(|s| !s.is_empty()).map(str::to_string)
}

fn n(v: &Value, ptr: &str) -> Option<u32> {
    v.pointer(ptr).and_then(Value::as_u64).and_then(|n| u32::try_from(n).ok())
}

/// Without `raw_json=1` Reddit escapes `&` in every URL.
fn unescape(u: String) -> String {
    if u.contains("&amp;") { u.replace("&amp;", "&") } else { u }
}

/// Every post or comment in a listing, a list of listings (a post page) or
/// a bare `{kind, data}` thing.
pub fn parse_listing(v: &Value) -> Vec<Item> {
    match v {
        Value::Array(parts) => parts.iter().flat_map(parse_listing).collect(),
        _ if v.get("kind").and_then(Value::as_str) == Some("Listing") => {
            v.pointer("/data/children").and_then(Value::as_array).into_iter().flatten().filter_map(parse_thing).collect()
        }
        _ => parse_thing(v).into_iter().collect(),
    }
}

fn parse_thing(t: &Value) -> Option<Item> {
    let data = t.get("data")?;
    match t.get("kind")?.as_str()? {
        "t3" => parse_post(data),
        "t1" => parse_comment(data),
        _ => None,
    }
}

fn permalink(d: &Value) -> Option<String> {
    let p = s(d, "/permalink")?;
    Some(if p.starts_with("http") { p } else { format!("https://www.reddit.com{p}") })
}

fn created(d: &Value) -> Option<i64> {
    let t = d.get("created_utc").and_then(Value::as_f64)?;
    if t.is_finite() && t >= i64::MIN as f64 && t < 9_223_372_036_854_775_808.0 { Some(t.trunc() as i64) } else { None }
}

fn post_media(d: &Value) -> Vec<Media> {
    // Native video: the fallback file is a plain mp4 (no audio track).
    if let Some(v) = d.pointer("/secure_media/reddit_video").or_else(|| d.pointer("/media/reddit_video"))
        && let Some(url) = s(v, "/fallback_url")
    {
        let poster = s(d, "/preview/images/0/source/url").map(unescape);
        return vec![Media {
            kind: MediaKind::Video,
            url: unescape(url),
            thumb_url: poster,
            file: None,
            video_file: None,
            width: n(v, "/width"),
            height: n(v, "/height"),
            alt: None,
        }];
    }
    // Galleries keep their order in gallery_data; the files are in media_metadata.
    if let Some(items) = d.pointer("/gallery_data/items").and_then(Value::as_array) {
        let meta = d.get("media_metadata");
        let pics: Vec<Media> = items
            .iter()
            .filter_map(|g| {
                let m = meta?.get(g.get("media_id")?.as_str()?)?;
                let url = s(m, "/s/u").or_else(|| s(m, "/s/gif"))?;
                Some(Media { width: n(m, "/s/x"), height: n(m, "/s/y"), alt: s(g, "/caption"), ..Media::image(unescape(url)) })
            })
            .collect();
        if !pics.is_empty() {
            return pics;
        }
    }
    let dest = s(d, "/url_overridden_by_dest").or_else(|| s(d, "/url")).map(unescape);
    if let Some(u) = dest {
        let path = u.split(['?', '#']).next().unwrap_or("");
        const IMAGE_EXTS: [&str; 5] = [".jpg", ".jpeg", ".png", ".webp", ".gif"];
        if IMAGE_EXTS.iter().any(|e| path.len() >= e.len() && path.get(path.len() - e.len()..).is_some_and(|tail| tail.eq_ignore_ascii_case(e))) {
            return vec![Media { width: n(d, "/preview/images/0/source/width"), height: n(d, "/preview/images/0/source/height"), ..Media::image(u) }];
        }
    }
    // A link post: its preview picture.
    s(d, "/preview/images/0/source/url")
        .map(|u| {
            vec![Media {
                width: n(d, "/preview/images/0/source/width"),
                height: n(d, "/preview/images/0/source/height"),
                ..Media::image(unescape(u))
            }]
        })
        .unwrap_or_default()
}

fn parse_post(d: &Value) -> Option<Item> {
    let id = s(d, "/id")?;
    let url = permalink(d)?;
    let text = tidy(&s(d, "/selftext").unwrap_or_default());
    let mut media = post_media(d);
    // A crosspost carries its media on the original.
    if media.is_empty()
        && let Some(orig) = d.pointer("/crosspost_parent_list/0")
    {
        media = post_media(orig);
    }
    let mut links = extract_urls(&text);
    if let Some(dest) = s(d, "/url_overridden_by_dest").map(unescape)
        && !dest.contains("redd.it")
        && !dest.contains("reddit.com")
        && media.iter().all(|m| m.url != dest)
    {
        links.insert(0, dest);
    }
    let author = s(d, "/author").filter(|a| a != "[deleted]");
    Some(Item {
        id: format!("reddit:{id}"),
        platform: Platform::Reddit,
        url,
        author_name: author.as_ref().map(|a| format!("u/{a}")),
        author_handle: author,
        title: s(d, "/title"),
        text,
        extra: s(d, "/subreddit_name_prefixed"),
        created_at: created(d),
        media,
        links,
        raw: Some(d.clone()),
        ..Default::default()
    })
}

fn parse_comment(d: &Value) -> Option<Item> {
    let id = s(d, "/id")?;
    let text = tidy(&s(d, "/body")?);
    let author = s(d, "/author").filter(|a| a != "[deleted]");
    Some(Item {
        // Not `reddit:<post id>`: that is the post the comment is under.
        id: format!("reddit:t1_{id}"),
        platform: Platform::Reddit,
        url: permalink(d).or_else(|| s(d, "/link_permalink"))?,
        author_name: author.as_ref().map(|a| format!("u/{a}")),
        author_handle: author,
        title: s(d, "/link_title"),
        links: extract_urls(&text),
        text,
        extra: s(d, "/subreddit_name_prefixed"),
        created_at: created(d),
        raw: Some(d.clone()),
        ..Default::default()
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn parses_saved_listing() {
        let v = json!({"kind": "Listing", "data": {"after": "t3_x", "children": [
            {"kind": "t3", "data": {
                "id": "abc12", "title": "Bir başlık", "selftext": "metin https://example.com/a",
                "author": "ali", "subreddit_name_prefixed": "r/turkey",
                "permalink": "/r/turkey/comments/abc12/bir_baslik/", "created_utc": 1700000000.0,
                "is_video": true,
                "secure_media": {"reddit_video": {"fallback_url": "https://v.redd.it/zz/DASH_720.mp4?source=fallback", "width": 720, "height": 1280}},
                "preview": {"images": [{"source": {"url": "https://preview.redd.it/p.jpg?a=1&amp;b=2", "width": 720, "height": 1280}}]}
            }},
            {"kind": "t3", "data": {
                "id": "gal1", "title": "Galeri", "author": "veli", "permalink": "/r/pics/comments/gal1/g/", "created_utc": 1700000001.0,
                "gallery_data": {"items": [{"media_id": "m2"}, {"media_id": "m1", "caption": "ikinci"}]},
                "media_metadata": {
                    "m1": {"s": {"u": "https://preview.redd.it/m1.jpg?x=1&amp;y=2", "x": 100, "y": 200}},
                    "m2": {"s": {"u": "https://preview.redd.it/m2.jpg", "x": 300, "y": 400}}
                }
            }},
            {"kind": "t1", "data": {
                "id": "c9", "body": "yorum", "author": "[deleted]", "link_title": "Ana gönderi",
                "permalink": "/r/rust/comments/p1/t/c9/", "created_utc": 1700000002.0
            }}
        ]}});
        let items = parse_listing(&v);
        assert_eq!(items.len(), 3);

        let video = &items[0];
        assert_eq!(video.id, "reddit:abc12");
        assert_eq!(video.url, "https://www.reddit.com/r/turkey/comments/abc12/bir_baslik/");
        assert_eq!(video.author_handle.as_deref(), Some("ali"));
        assert_eq!(video.media[0].kind, MediaKind::Video);
        assert!(video.media[0].downloadable_video().is_some());
        assert_eq!(video.media[0].thumb_url.as_deref(), Some("https://preview.redd.it/p.jpg?a=1&b=2"));
        assert_eq!(video.links, vec!["https://example.com/a"]);
        assert_eq!(video.created_at, Some(1700000000));

        let gallery = &items[1];
        assert_eq!(gallery.media.len(), 2);
        assert_eq!(gallery.media[0].url, "https://preview.redd.it/m2.jpg");
        assert_eq!(gallery.media[1].url, "https://preview.redd.it/m1.jpg?x=1&y=2");
        assert_eq!(gallery.media[1].alt.as_deref(), Some("ikinci"));

        let comment = &items[2];
        assert_eq!(comment.id, "reddit:t1_c9");
        assert_eq!(comment.author_handle, None);
        assert_eq!(comment.title.as_deref(), Some("Ana gönderi"));
    }

    #[test]
    fn link_post_keeps_destination() {
        let v = json!({"kind": "t3", "data": {
            "id": "l1", "title": "Makale", "author": "a", "permalink": "/r/x/comments/l1/m/",
            "url_overridden_by_dest": "https://blog.example.com/yazi",
            "preview": {"images": [{"source": {"url": "https://external-preview.redd.it/k.jpg", "width": 10, "height": 10}}]}
        }});
        let items = parse_listing(&v);
        assert_eq!(items[0].links, vec!["https://blog.example.com/yazi"]);
        assert_eq!(items[0].media[0].url, "https://external-preview.redd.it/k.jpg");
    }
}
