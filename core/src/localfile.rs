//! Importing pictures and videos from disk: old TikTok downloads, screen
//! recordings, a folder of saved memes.
//!
//! A file whose name carries a post id (`7194…3.mp4`, `Title [dQw4w9WgXcQ].mp4`)
//! is tied to that post: an item already in the library gets the file as
//! its video, otherwise a stub for the post is made with the file attached,
//! and the caption and author are fetched later. Other files become `local`
//! items, one per file, with the same content always the same item.

use std::path::{Path, PathBuf};

use crate::model::MediaKind;

const VIDEO_EXT: [&str; 4] = ["mp4", "mov", "m4v", "3gp"];
const IMAGE_EXT: [&str; 7] = ["jpg", "jpeg", "png", "heic", "gif", "webp", "avif"];

/// What kind of media a file is, by its extension.
pub fn kind_of(path: &Path) -> Option<MediaKind> {
    let ext = path.extension()?.to_str()?.to_ascii_lowercase();
    if VIDEO_EXT.contains(&ext.as_str()) {
        Some(MediaKind::Video)
    } else if IMAGE_EXT.contains(&ext.as_str()) {
        Some(MediaKind::Image)
    } else {
        None
    }
}

pub fn content_type(path: &Path) -> &'static str {
    match path.extension().and_then(|e| e.to_str()).map(str::to_ascii_lowercase).as_deref() {
        Some("mp4" | "m4v" | "3gp") => "video/mp4",
        Some("mov") => "video/quicktime",
        Some("png") => "image/png",
        Some("gif") => "image/gif",
        Some("webp") => "image/webp",
        Some("heic") => "image/heic",
        Some("avif") => "image/avif",
        _ => "image/jpeg",
    }
}

/// Every media file under the given files and folders (hidden ones and
/// macOS metadata skipped), in a stable order.
pub fn collect(paths: &[PathBuf]) -> Vec<PathBuf> {
    fn walk(p: &Path, depth: usize, out: &mut Vec<PathBuf>) {
        let hidden = p.file_name().and_then(|n| n.to_str()).is_some_and(|n| n.starts_with('.') || n == "__MACOSX");
        if hidden || depth > 10 {
            return;
        }
        if p.is_dir() {
            let Ok(entries) = std::fs::read_dir(p) else { return };
            let mut children: Vec<PathBuf> = entries.flatten().map(|e| e.path()).collect();
            children.sort();
            for c in children {
                walk(&c, depth + 1, out);
            }
        } else if kind_of(p).is_some() {
            out.push(p.to_path_buf());
        }
    }
    let mut out = vec![];
    for p in paths {
        walk(p, 0, &mut out);
    }
    out
}

/// A TikTok video id in a file name: a run of 19 digits starting with 6 or 7.
pub fn tiktok_id(name: &str) -> Option<String> {
    let mut run = String::new();
    for c in name.chars().chain(std::iter::once(' ')) {
        if c.is_ascii_digit() {
            run.push(c);
            continue;
        }
        if run.len() == 19 && (run.starts_with('7') || run.starts_with('6')) {
            return Some(run);
        }
        run.clear();
    }
    None
}

/// A YouTube id as yt-dlp writes it: `Title [dQw4w9WgXcQ].mp4`.
pub fn youtube_id(name: &str) -> Option<String> {
    let start = name.rfind('[')?;
    let rest = name.get(start + 1..)?;
    let id = rest.get(..rest.find(']')?)?;
    (id.len() == 11 && id.chars().all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')).then(|| id.to_string())
}

/// When the file was made (falls back to last modified), unix seconds.
pub fn file_time(path: &Path) -> Option<i64> {
    let meta = std::fs::metadata(path).ok()?;
    let t = meta.created().or_else(|_| meta.modified()).ok()?;
    t.duration_since(std::time::UNIX_EPOCH).ok().and_then(|d| i64::try_from(d.as_secs()).ok())
}

/// `file://` URL for a path.
pub fn file_url(path: &Path) -> String {
    url::Url::from_file_path(path).map(|u| u.to_string()).unwrap_or_else(|_| format!("file://{}", path.display()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn finds_post_ids_in_names() {
        assert_eq!(tiktok_id("7194000000000000001.mp4").as_deref(), Some("7194000000000000001"));
        assert_eq!(tiktok_id("SnapTik.App_7194000000000000001-HD.mp4").as_deref(), Some("7194000000000000001"));
        assert_eq!(tiktok_id("ssstik.io_1700000000000.mp4"), None);
        assert_eq!(tiktok_id("71940000000000000012.mp4"), None);
        assert_eq!(youtube_id("Never Gonna [dQw4w9WgXcQ].mp4").as_deref(), Some("dQw4w9WgXcQ"));
        assert_eq!(youtube_id("x [short].mp4"), None);
        assert_eq!(kind_of(Path::new("a.MOV")), Some(MediaKind::Video));
        assert_eq!(kind_of(Path::new("a.txt")), None);
    }
}
