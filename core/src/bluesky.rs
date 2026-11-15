//! Bluesky saved posts and likes, from the AT Protocol responses the web
//! app already receives (`app.bsky.bookmark.getBookmarks`,
//! `app.bsky.feed.getActorLikes`): every `postView` with its pictures,
//! video, quoted post and links.

use serde_json::Value;

use crate::model::{Item, Media, MediaKind, Platform};
use crate::text::tidy;

fn s(v: &Value, ptr: &str) -> Option<String> {
    v.pointer(ptr).and_then(Value::as_str).filter(|x| !x.is_empty()).map(str::to_string)
}

fn rkey(uri: &str) -> Option<&str> {
    uri.rsplit('/').next().filter(|k| !k.is_empty())
}

fn time(v: &Value, ptr: &str) -> Option<i64> {
    chrono::DateTime::parse_from_rfc3339(v.pointer(ptr)?.as_str()?).ok().map(|d| d.timestamp())
}

/// Pictures / video of an embed view (images, video, or the media half
/// of a quote-with-media).
fn embed_media(e: &Value) -> Vec<Media> {
    let ty = e.get("$type").and_then(Value::as_str).unwrap_or("");
    if ty.starts_with("app.bsky.embed.recordWithMedia") {
        return e.get("media").map(embed_media).unwrap_or_default();
    }
    if let Some(imgs) = e.get("images").and_then(Value::as_array) {
        return imgs
            .iter()
            .filter_map(|i| {
                let mut m = Media::image(s(i, "/fullsize").or_else(|| s(i, "/thumb"))?);
                m.alt = s(i, "/alt");
                m.width = i.pointer("/aspectRatio/width").and_then(Value::as_u64).and_then(|w| u32::try_from(w).ok());
                m.height = i.pointer("/aspectRatio/height").and_then(Value::as_u64).and_then(|h| u32::try_from(h).ok());
                Some(m)
            })
            .collect();
    }
    if let Some(playlist) = s(e, "/playlist") {
        let mut m = Media::image(playlist);
        m.kind = MediaKind::Video;
        m.thumb_url = s(e, "/thumbnail");
        m.alt = s(e, "/alt");
        return vec![m];
    }
    vec![]
}

fn post_url(handle: &str, uri: &str) -> String {
    format!("https://bsky.app/profile/{handle}/post/{}", rkey(uri).unwrap_or(""))
}

/// A quoted post (`app.bsky.embed.record#viewRecord`).
fn quote(e: &Value) -> Option<Item> {
    let rec = e.pointer("/record/record").or_else(|| e.get("record"))?;
    let uri = rec.get("uri")?.as_str()?;
    let handle = s(rec, "/author/handle")?;
    let media = rec.get("embeds").and_then(Value::as_array).map(|a| a.iter().flat_map(embed_media).collect()).unwrap_or_default();
    Some(Item {
        id: format!("bluesky:{}", rkey(uri)?),
        platform: Platform::Bluesky,
        url: post_url(&handle, uri),
        author_handle: Some(handle),
        author_name: s(rec, "/author/displayName"),
        author_avatar: s(rec, "/author/avatar"),
        text: tidy(&s(rec, "/value/text").unwrap_or_default()),
        created_at: time(rec, "/value/createdAt"),
        media,
        ..Default::default()
    })
}

fn parse_post(p: &Value) -> Option<Item> {
    let uri = p.get("uri")?.as_str()?;
    let handle = s(p, "/author/handle")?;
    let mut links: Vec<String> = p
        .pointer("/record/facets")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .flat_map(|f| f.get("features").and_then(Value::as_array).into_iter().flatten())
        .filter_map(|f| s(f, "/uri"))
        .collect();
    let embed = p.get("embed");
    if let Some(ext) = embed.and_then(|e| s(e, "/external/uri")) {
        links.push(ext);
    }
    links.dedup();
    let quoted = embed.filter(|e| e.get("$type").and_then(Value::as_str).is_some_and(|t| t.contains("record"))).and_then(quote);
    Some(Item {
        id: format!("bluesky:{}", rkey(uri)?),
        platform: Platform::Bluesky,
        url: post_url(&handle, uri),
        author_handle: Some(handle),
        author_name: s(p, "/author/displayName"),
        author_avatar: s(p, "/author/avatar"),
        text: tidy(&s(p, "/record/text").unwrap_or_default()),
        created_at: time(p, "/record/createdAt"),
        media: embed.map(embed_media).unwrap_or_default(),
        links,
        quote: quoted.map(Box::new),
        raw: Some(p.clone()),
        ..Default::default()
    })
}

/// Every post in a bookmarks / likes / feed response, each once, in order.
/// Reply context (`reply.parent`, `reply.root`) is not something you saved.
pub fn parse_api(v: &Value) -> Vec<Item> {
    fn walk(v: &Value, out: &mut Vec<Item>) {
        match v {
            Value::Object(map) => {
                let is_post = map.get("uri").and_then(Value::as_str).is_some_and(|u| u.starts_with("at://"))
                    && map.get("record").and_then(|r| r.get("$type")).and_then(Value::as_str) == Some("app.bsky.feed.post")
                    && map.contains_key("author");
                if is_post {
                    if let Some(i) = parse_post(v) {
                        out.push(i);
                    }
                    return;
                }
                for (k, c) in map {
                    if k != "reply" && k != "parent" && k != "root" {
                        walk(c, out);
                    }
                }
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
    fn reads_bookmarks() {
        let v: Value = serde_json::from_str(
            r#"{"bookmarks":[{"createdAt":"2025-10-01T10:00:00Z","item":{
              "uri":"at://did:plc:abc/app.bsky.feed.post/3lxyz","cid":"c",
              "author":{"did":"did:plc:abc","handle":"ali.bsky.social","displayName":"Ali"},
              "record":{"$type":"app.bsky.feed.post","text":"Merhaba https://e.com","createdAt":"2025-09-30T08:00:00.000Z",
                "facets":[{"features":[{"$type":"app.bsky.richtext.facet#link","uri":"https://e.com/uzun"}]}]},
              "embed":{"$type":"app.bsky.embed.images#view","images":[{"thumb":"https://cdn/t.jpg","fullsize":"https://cdn/f.jpg","alt":"kedi","aspectRatio":{"width":4,"height":3}}]}},
              "reply":{"parent":{"uri":"at://did:plc:x/app.bsky.feed.post/3par","author":{"handle":"x"},"record":{"$type":"app.bsky.feed.post","text":"no"}}}}]}"#,
        )
        .unwrap_or_default();
        let items = parse_api(&v);
        assert_eq!(items.len(), 1);
        let a = items.first().cloned().unwrap_or_default();
        assert_eq!(a.id, "bluesky:3lxyz");
        assert_eq!(a.url, "https://bsky.app/profile/ali.bsky.social/post/3lxyz");
        assert_eq!(a.media.first().map(|m| (m.url.as_str(), m.alt.as_deref())), Some(("https://cdn/f.jpg", Some("kedi"))));
        assert_eq!(a.links, vec!["https://e.com/uzun".to_string()]);
        assert_eq!(a.created_at, Some(1759219200));
        assert_eq!(crate::text::item_id_for_url(&a.url).1, "bluesky:3lxyz");
    }
}
