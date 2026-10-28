//! TikTok `itemStruct` → [`Item`].
//!
//! The same object shape appears in the video page's rehydration JSON and in
//! the web app's own API responses (favorites, likes, profile lists), so the
//! URL capturer and the extensions share this parser.

use serde_json::Value;

use crate::model::{Item, Media, MediaKind, Platform};
use crate::text::{extract_urls, tidy};

fn str_at(v: &Value, ptr: &str) -> Option<String> {
    v.pointer(ptr).and_then(Value::as_str).filter(|s| !s.is_empty()).map(str::to_string)
}

fn num_at(v: &Value, ptr: &str) -> Option<u64> {
    let x = v.pointer(ptr)?;
    x.as_u64().or_else(|| x.as_str().and_then(|s| s.parse().ok()))
}

fn dim(v: &Value, ptr: &str) -> Option<u32> {
    num_at(v, ptr).and_then(|n| u32::try_from(n).ok())
}

pub fn parse_item_struct(it: &Value) -> Option<Item> {
    let id = str_at(it, "/id")?;
    let handle = str_at(it, "/author/uniqueId").or_else(|| str_at(it, "/author"));
    // Photo carousels live under /photo/, videos under /video/.
    let is_photo = it.pointer("/imagePost/images").and_then(Value::as_array).is_some_and(|a| !a.is_empty());
    let kind = if is_photo { "photo" } else { "video" };
    let url = match &handle {
        Some(h) => format!("https://www.tiktok.com/@{h}/{kind}/{id}"),
        None => format!("https://www.tiktok.com/{kind}/{id}"),
    };
    let text = tidy(&str_at(it, "/desc").unwrap_or_default());

    // Photo carousels carry their images; videos get a poster.
    let mut media: Vec<Media> = it
        .pointer("/imagePost/images")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|img| {
            // Each picture comes in several encodings; JPEG decodes
            // everywhere (HEIC is often listed first).
            let urls: Vec<&str> = img.pointer("/imageURL/urlList")?.as_array()?.iter().filter_map(Value::as_str).collect();
            let src = urls.iter().find(|u| u.contains(".jpeg") || u.contains(".jpg")).or(urls.first())?.to_string();
            Some(Media { width: dim(img, "/imageWidth"), height: dim(img, "/imageHeight"), ..Media::image(src) })
        })
        .collect();
    if media.is_empty() {
        let poster = str_at(it, "/video/originCover").or_else(|| str_at(it, "/video/cover"));
        if let Some(poster) = poster {
            media.push(Media {
                kind: MediaKind::Video,
                url: url.clone(),
                thumb_url: Some(poster),
                file: None,
                video_file: None,
                width: dim(it, "/video/width"),
                height: dim(it, "/video/height"),
                alt: None,
            });
        }
    }
    Some(Item {
        id: format!("tiktok:{id}"),
        platform: Platform::Tiktok,
        author_handle: handle,
        author_name: str_at(it, "/author/nickname"),
        author_avatar: str_at(it, "/author/avatarThumb"),
        links: extract_urls(&text),
        text,
        created_at: num_at(it, "/createTime").and_then(|t| i64::try_from(t).ok()),
        media,
        raw: Some(it.clone()),
        url,
        ..Default::default()
    })
}

/// The video page's embedded state (`__UNIVERSAL_DATA_FOR_REHYDRATION__`).
pub fn parse_video_page(html: &str) -> Option<Item> {
    let marker = "id=\"__UNIVERSAL_DATA_FOR_REHYDRATION__\"";
    let start = html.find(marker)?;
    let body_start = start + html[start..].find('>')? + 1;
    let body_end = body_start + html[body_start..].find("</script>")?;
    let state: Value = serde_json::from_str(&html[body_start..body_end]).ok()?;
    parse_item_struct(state.pointer("/__DEFAULT_SCOPE__/webapp.video-detail/itemInfo/itemStruct")?)
}

/// Every item in a TikTok web API response (`itemList`, `items`, …).
pub fn parse_api(v: &Value) -> Vec<Item> {
    fn walk(v: &Value, out: &mut Vec<Item>) {
        match v {
            Value::Object(map) => {
                let looks_like_item = map.contains_key("id") && map.contains_key("desc") && map.contains_key("author");
                if looks_like_item && let Some(item) = parse_item_struct(v) {
                    if !out.iter().any(|o| o.id == item.id) {
                        out.push(item);
                    }
                    return;
                }
                map.values().for_each(|c| walk(c, out));
            }
            Value::Array(a) => a.iter().for_each(|c| walk(c, out)),
            _ => {}
        }
    }
    let mut out = vec![];
    walk(v, &mut out);
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn parses_video_page_and_photo_posts() {
        let state = json!({ "__DEFAULT_SCOPE__": { "webapp.video-detail": { "itemInfo": { "itemStruct": {
            "id": "671", "desc": "Selam #fyp", "createTime": "1564234358",
            "author": { "uniqueId": "scout2015", "nickname": "Scout" },
            "video": { "cover": "https://p16/cover.jpg", "width": 576, "height": 1024 }
        }}}}});
        let html = format!(r#"<html><script id="__UNIVERSAL_DATA_FOR_REHYDRATION__" type="application/json">{state}</script></html>"#);
        let item = parse_video_page(&html).unwrap();
        assert_eq!(item.id, "tiktok:671");
        assert_eq!(item.url, "https://www.tiktok.com/@scout2015/video/671");
        assert_eq!(item.created_at, Some(1564234358));
        assert_eq!(item.media[0].thumb_url.as_deref(), Some("https://p16/cover.jpg"));

        let api = json!({ "itemList": [{ "id": "9", "desc": "foto", "author": { "uniqueId": "a" },
            "imagePost": { "images": [{ "imageURL": { "urlList": ["https://p16/1.heic", "https://p16/1.jpeg"] } }] } }] });
        let items = parse_api(&api);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0].media[0].kind, MediaKind::Image);
        assert_eq!(items[0].media[0].url, "https://p16/1.jpeg");
        assert_eq!(items[0].url, "https://www.tiktok.com/@a/photo/9");
    }
}
