//! YouTube lists (Watch Later, Liked videos, your playlists), as the
//! extension sees them on the playlist page: `ytInitialData` and the
//! `youtubei/v1/browse` continuation responses. Either the site's own
//! `playlistVideoRenderer` objects or the extension's slim copies
//! (`{videoId, title, channel, handle, thumb, seconds}`).
//!
//! Videos are not downloaded (`platform:youtube` is left out of the video
//! queue); the poster, title and channel are kept.

use serde_json::Value;

use crate::model::{Item, Media, MediaKind, Platform};

fn text(v: Option<&Value>) -> Option<String> {
    let v = v?;
    if let Some(s) = v.as_str() {
        return Some(s.to_string());
    }
    if let Some(s) = v.get("simpleText").and_then(Value::as_str) {
        return Some(s.to_string());
    }
    let runs = v.get("runs")?.as_array()?;
    let joined: String = runs.iter().filter_map(|r| r.get("text").and_then(Value::as_str)).collect();
    (!joined.is_empty()).then_some(joined)
}

fn item(video_id: &str, title: Option<String>, channel: Option<String>, handle: Option<String>, thumb: Option<String>) -> Item {
    let url = format!("https://www.youtube.com/watch?v={video_id}");
    let mut m = Media::image(url.clone());
    m.kind = MediaKind::Video;
    m.thumb_url = Some(thumb.unwrap_or_else(|| format!("https://i.ytimg.com/vi/{video_id}/hqdefault.jpg")));
    Item {
        id: format!("youtube:{video_id}"),
        platform: Platform::Youtube,
        url,
        author_handle: handle,
        author_name: channel,
        title,
        media: vec![m],
        ..Default::default()
    }
}

fn from_renderer(r: &Value) -> Option<Item> {
    let id = r.get("videoId")?.as_str()?;
    let byline = r.get("shortBylineText").or_else(|| r.get("longBylineText"));
    let channel = text(byline);
    let handle = byline
        .and_then(|b| b.pointer("/runs/0/navigationEndpoint/browseEndpoint/canonicalBaseUrl"))
        .and_then(Value::as_str)
        .and_then(|u| u.strip_prefix("/@"))
        .map(str::to_string);
    let thumb =
        r.pointer("/thumbnail/thumbnails").and_then(Value::as_array).and_then(|a| a.last()).and_then(|t| t.get("url")).and_then(Value::as_str);
    Some(item(id, text(r.get("title")), channel, handle, thumb.map(|t| t.split('?').next().unwrap_or(t).to_string())))
}

fn from_slim(r: &Value) -> Option<Item> {
    let id = r.get("videoId")?.as_str()?;
    let s = |k: &str| r.get(k).and_then(Value::as_str).filter(|v| !v.is_empty()).map(str::to_string);
    Some(item(id, s("title"), s("channel"), s("handle").map(|h| h.trim_start_matches('@').to_string()), s("thumb")))
}

/// Every video in the payload, in list order, each once.
pub fn parse_api(v: &Value) -> Vec<Item> {
    fn walk(v: &Value, out: &mut Vec<Item>) {
        match v {
            Value::Object(map) => {
                for key in ["playlistVideoRenderer", "playlistPanelVideoRenderer", "videoRenderer"] {
                    if let Some(i) = map.get(key).and_then(from_renderer) {
                        out.push(i);
                        return;
                    }
                }
                if map.contains_key("videoId") && map.contains_key("channel") {
                    if let Some(i) = from_slim(v) {
                        out.push(i);
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
    let mut seen = std::collections::HashSet::new();
    out.retain(|i| seen.insert(i.id.clone()));
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_playlists() {
        let v: Value = serde_json::from_str(
            r#"{"contents":[{"playlistVideoRenderer":{"videoId":"dQw4w9WgXcQ","title":{"runs":[{"text":"Never Gonna"}]},
              "shortBylineText":{"runs":[{"text":"Rick Astley","navigationEndpoint":{"browseEndpoint":{"canonicalBaseUrl":"/@RickAstleyYT"}}}]},
              "thumbnail":{"thumbnails":[{"url":"https://i.ytimg.com/vi/dQw4w9WgXcQ/default.jpg"},{"url":"https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg?sqp=x"}]}}},
              {"videoId":"abcdefghijk","title":"Slim","channel":"Kanal","handle":"@kanal","thumb":""}]}"#,
        )
        .unwrap_or_default();
        let items = parse_api(&v);
        assert_eq!(items.len(), 2);
        let a = items.first().cloned().unwrap_or_default();
        assert_eq!(
            (a.id.as_str(), a.title.as_deref(), a.author_handle.as_deref()),
            ("youtube:dQw4w9WgXcQ", Some("Never Gonna"), Some("RickAstleyYT"))
        );
        assert_eq!(a.media.first().and_then(|m| m.thumb_url.as_deref()), Some("https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg"));
        let b = items.get(1).cloned().unwrap_or_default();
        assert_eq!((b.author_name.as_deref(), b.author_handle.as_deref()), (Some("Kanal"), Some("kanal")));
        assert_eq!(b.media.first().and_then(|m| m.thumb_url.as_deref()), Some("https://i.ytimg.com/vi/abcdefghijk/hqdefault.jpg"));
    }
}
