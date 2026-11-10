//! Instagram web API media objects → [`Item`].
//!
//! The extension listens to the responses instagram.com's own web client
//! receives on the Saved page (REST `feed/saved/posts` or the GraphQL
//! connection that replaced it). Both carry the same media object, so the
//! payload is walked for anything shaped like one, wherever it sits.

use std::collections::HashSet;

use serde_json::Value;

use crate::model::{Item, Media, MediaKind, Platform};
use crate::text::{extract_urls, tidy};

fn s(v: &Value, ptr: &str) -> Option<String> {
    v.pointer(ptr).and_then(Value::as_str).filter(|s| !s.is_empty()).map(str::to_string)
}

fn n(v: &Value, ptr: &str) -> Option<u32> {
    v.pointer(ptr).and_then(Value::as_u64).and_then(|n| u32::try_from(n).ok())
}

fn is_media(v: &Value) -> bool {
    v.get("code").and_then(Value::as_str).is_some()
        && v.get("taken_at").is_some()
        && (v.get("image_versions2").is_some() || v.get("carousel_media").is_some() || v.get("video_versions").is_some())
}

/// Every post found in the payload, first appearance first.
pub fn parse_api(v: &Value) -> Vec<Item> {
    let mut out = vec![];
    let mut seen = HashSet::new();
    walk(v, &mut out, &mut seen);
    out
}

fn walk<'a>(v: &'a Value, out: &mut Vec<Item>, seen: &mut HashSet<&'a str>) {
    match v {
        Value::Array(a) => a.iter().for_each(|x| walk(x, out, seen)),
        Value::Object(o) => {
            if is_media(v) {
                if let Some(code) = v.get("code").and_then(Value::as_str)
                    && !seen.contains(code)
                    && let Some(item) = parse_media(v)
                {
                    seen.insert(code);
                    out.push(item);
                }
                return;
            }
            o.values().for_each(|x| walk(x, out, seen));
        }
        _ => {}
    }
}

/// The largest picture; the list is not always sorted.
fn best_image(m: &Value) -> Option<(String, Option<u32>, Option<u32>)> {
    let c = m.pointer("/image_versions2/candidates")?.as_array()?;
    let best = c.iter().max_by_key(|x| x.get("width").and_then(Value::as_u64).unwrap_or(0))?;
    Some((s(best, "/url")?, n(best, "/width"), n(best, "/height")))
}

fn one(m: &Value) -> Option<Media> {
    let (img, w, h) = match best_image(m) {
        Some((u, w, h)) => (Some(u), w, h),
        None => (None, None, None),
    };
    let alt = s(m, "/accessibility_caption");
    if let Some(video) = m.get("video_versions").and_then(Value::as_array).and_then(|v| v.first()) {
        return Some(Media {
            kind: MediaKind::Video,
            url: s(video, "/url")?,
            thumb_url: img,
            file: None,
            video_file: None,
            width: n(video, "/width").or(w),
            height: n(video, "/height").or(h),
            alt,
        });
    }
    Some(Media { width: w, height: h, alt, ..Media::image(img?) })
}

pub fn parse_media(m: &Value) -> Option<Item> {
    let code = s(m, "/code")?;
    let is_reel = m.get("product_type").and_then(Value::as_str) == Some("clips");
    let url = format!("https://www.instagram.com/{}/{code}/", if is_reel { "reel" } else { "p" });
    let text = tidy(&s(m, "/caption/text").unwrap_or_default());
    let media: Vec<Media> = match m.get("carousel_media").and_then(Value::as_array) {
        Some(parts) => parts.iter().filter_map(one).collect(),
        None => one(m).into_iter().collect(),
    };
    Some(Item {
        id: format!("instagram:{code}"),
        platform: Platform::Instagram,
        url,
        author_handle: s(m, "/user/username").or_else(|| s(m, "/owner/username")),
        author_name: s(m, "/user/full_name").or_else(|| s(m, "/owner/full_name")),
        author_avatar: s(m, "/user/profile_pic_url").or_else(|| s(m, "/owner/profile_pic_url")),
        links: extract_urls(&text),
        text,
        created_at: m.get("taken_at").and_then(Value::as_i64),
        media,
        raw: Some(m.clone()),
        ..Default::default()
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn img(url: &str, w: u32) -> Value {
        json!({"url": url, "width": w, "height": w})
    }

    #[test]
    fn parses_saved_feed() {
        let v = json!({"items": [
            {"media": {
                "code": "Cabc", "taken_at": 1700000000, "media_type": 1,
                "caption": {"text": "kahvaltı https://ornek.com"},
                "user": {"username": "ayse", "full_name": "Ayşe"},
                "image_versions2": {"candidates": [img("https://cdn/small.jpg", 320), img("https://cdn/big.jpg", 1080)]}
            }},
            {"media": {
                "code": "Creel", "taken_at": 1700000001, "media_type": 2, "product_type": "clips", "caption": null,
                "user": {"username": "mehmet"},
                "image_versions2": {"candidates": [img("https://cdn/poster.jpg", 640)]},
                "video_versions": [{"url": "https://cdn/v.mp4?x=1", "width": 720, "height": 1280}]
            }},
            {"media": {
                "code": "Ccar", "taken_at": 1700000002, "media_type": 8,
                "user": {"username": "zeynep"},
                "carousel_media": [
                    {"image_versions2": {"candidates": [img("https://cdn/1.jpg", 1080)]}},
                    {"image_versions2": {"candidates": [img("https://cdn/2p.jpg", 640)]}, "video_versions": [{"url": "https://cdn/2.mp4"}]}
                ]
            }}
        ], "more_available": true});
        let items = parse_api(&v);
        assert_eq!(items.len(), 3);
        assert_eq!(items[0].id, "instagram:Cabc");
        assert_eq!(items[0].url, "https://www.instagram.com/p/Cabc/");
        assert_eq!(items[0].media[0].url, "https://cdn/big.jpg");
        assert_eq!(items[0].links, vec!["https://ornek.com"]);
        assert_eq!(items[1].url, "https://www.instagram.com/reel/Creel/");
        assert_eq!(items[1].media[0].kind, MediaKind::Video);
        assert!(items[1].media[0].downloadable_video().is_some());
        assert_eq!(items[1].media[0].thumb_url.as_deref(), Some("https://cdn/poster.jpg"));
        assert_eq!(items[2].media.len(), 2);
        assert_eq!(items[2].media[1].kind, MediaKind::Video);
    }

    #[test]
    fn walks_graphql_edges_once() {
        let m = json!({"code": "Cg", "taken_at": 1, "image_versions2": {"candidates": [img("https://cdn/g.jpg", 10)]}, "user": {"username": "u"}});
        let v = json!({"data": {"xdt_api__v1__feed__saved__posts__connection": {"edges": [{"node": {"media": m.clone()}}, {"node": {"media": m}}]}}});
        assert_eq!(parse_api(&v).len(), 1);
    }
}
