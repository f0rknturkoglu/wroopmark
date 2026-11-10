//! Content-addressed media files: `media/<ab>/<xxh3-128>.<ext>`.
//!
//! The same image saved twice is one file, and two devices can never write
//! different bytes under one name — which is what makes folder sync safe.

use std::fs;
use std::io::{self, Read, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

use xxhash_rust::xxh3::Xxh3;

use crate::text::hash_hex;

pub struct MediaStore {
    root: PathBuf,
}

/// True for names this store hands out (`<32 hex>.<ext>`). Anything else —
/// a path, `..` — is refused wherever a name could come from outside.
pub fn is_name(name: &str) -> bool {
    let Some((hash, ext)) = name.split_once('.') else { return false };
    hash.len() == 32
        && hash.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'))
        && (1..=5).contains(&ext.len())
        && ext.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit())
}

/// A temp file name no other writer (thread or process) is using.
fn tmp_name() -> String {
    static SEQ: AtomicU64 = AtomicU64::new(0);
    format!(".dl-{}-{}.tmp", std::process::id(), SEQ.fetch_add(1, Ordering::Relaxed))
}

/// File extension for a response content type (or sniffed bytes).
pub fn ext_for(content_type: &str, bytes: &[u8]) -> &'static str {
    let ct = content_type.split(';').next().unwrap_or("").trim();
    if ct.eq_ignore_ascii_case("image/jpeg") || ct.eq_ignore_ascii_case("image/jpg") {
        return "jpg";
    }
    if ct.eq_ignore_ascii_case("image/png") {
        return "png";
    }
    if ct.eq_ignore_ascii_case("image/webp") {
        return "webp";
    }
    if ct.eq_ignore_ascii_case("image/gif") {
        return "gif";
    }
    if ct.eq_ignore_ascii_case("image/avif") {
        return "avif";
    }
    if ct.eq_ignore_ascii_case("image/heic") {
        return "heic";
    }
    if ct.eq_ignore_ascii_case("video/mp4") {
        return "mp4";
    }
    match bytes {
        [0xFF, 0xD8, 0xFF, ..] => "jpg",
        [0x89, b'P', b'N', b'G', ..] => "png",
        [b'G', b'I', b'F', b'8', ..] => "gif",
        [b'R', b'I', b'F', b'F', _, _, _, _, b'W', b'E', b'B', b'P', ..] => "webp",
        [_, _, _, _, b'f', b't', b'y', b'p', b'a', b'v', b'i', b'f', ..] => "avif",
        [_, _, _, _, b'f', b't', b'y', b'p', ..] => "mp4",
        _ => "bin",
    }
}

impl MediaStore {
    pub fn new(root: impl Into<PathBuf>) -> Self {
        Self { root: root.into() }
    }

    pub fn root(&self) -> &Path {
        &self.root
    }

    /// Absolute path for a stored name (`<hash>.<ext>`). Callers holding a
    /// name from outside check it with [`is_name`] first.
    pub fn path(&self, name: &str) -> PathBuf {
        self.root.join(name.get(..2).unwrap_or("00")).join(name)
    }

    pub fn contains(&self, name: &str) -> bool {
        is_name(name) && self.path(name).is_file()
    }

    /// Size of a stored file in bytes, if it exists.
    pub fn file_size(&self, name: &str) -> Option<i64> {
        if is_name(name) { fs::metadata(self.path(name)).ok().and_then(|m| i64::try_from(m.len()).ok()) } else { None }
    }

    /// Stores the bytes and returns their name. Writes go through a temp file
    /// and a rename, so a crash never leaves a half file under a real name.
    pub fn put(&self, bytes: &[u8], ext: &str) -> io::Result<String> {
        let name = format!("{}.{ext}", hash_hex(bytes));
        let path = self.path(&name);
        if path.is_file() {
            return Ok(name);
        }
        let dir = path.parent().ok_or_else(|| io::Error::other("geçersiz medya yolu"))?;
        fs::create_dir_all(dir)?;
        let tmp = dir.join(tmp_name());
        let result = (|| {
            let mut f = fs::File::create(&tmp)?;
            f.write_all(bytes)?;
            f.sync_all()?;
            drop(f);
            fs::rename(&tmp, &path)?;
            Ok(name)
        })();
        if result.is_err() {
            let _ = fs::remove_file(&tmp);
        }
        result
    }

    /// Streams a download to disk while hashing it, so a 300 MB video never
    /// sits in memory. Same naming as [`put`](Self::put).
    pub fn put_reader(&self, mut r: impl Read, content_type: &str) -> io::Result<String> {
        fs::create_dir_all(&self.root)?;
        let tmp = self.root.join(tmp_name());
        let result = (|| {
            let mut f = fs::File::create(&tmp)?;
            let mut hasher = Xxh3::new();
            let mut head = [0u8; 16];
            let mut head_len = 0usize;
            let mut buf = vec![0u8; 256 * 1024];
            loop {
                let n = match r.read(&mut buf) {
                    Ok(0) => break,
                    Ok(n) => n,
                    Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
                    Err(e) => return Err(e),
                };
                let chunk = buf.get(..n).ok_or_else(|| io::Error::other("okuma boyutu aşıldı"))?;
                if head_len < head.len() {
                    let take = n.min(head.len() - head_len);
                    if let (Some(dst), Some(src)) = (head.get_mut(head_len..head_len + take), chunk.get(..take)) {
                        dst.copy_from_slice(src);
                        head_len += take;
                    }
                }
                hasher.update(chunk);
                f.write_all(chunk)?;
            }
            let head_slice = head.get(..head_len).unwrap_or(&[]);
            if head_slice.is_empty() {
                return Err(io::Error::new(io::ErrorKind::UnexpectedEof, "boş yanıt"));
            }
            f.sync_all()?;
            drop(f);
            let name = format!("{:032x}.{}", hasher.digest128(), ext_for(content_type, head_slice));
            let path = self.path(&name);
            if path.is_file() {
                fs::remove_file(&tmp)?;
            } else {
                let dir = path.parent().ok_or_else(|| io::Error::other("geçersiz medya yolu"))?;
                fs::create_dir_all(dir)?;
                fs::rename(&tmp, &path)?;
            }
            Ok(name)
        })();
        if result.is_err() {
            let _ = fs::remove_file(&tmp);
        }
        result
    }

    /// Total size of stored media, in bytes.
    pub fn bytes(&self) -> u64 {
        let Ok(dirs) = fs::read_dir(&self.root) else { return 0 };
        dirs.flatten()
            .filter(|d| d.file_type().is_ok_and(|t| t.is_dir()))
            .filter_map(|d| fs::read_dir(d.path()).ok())
            .flat_map(|files| files.flatten())
            .filter(|f| f.file_type().is_ok_and(|t| t.is_file()))
            .filter_map(|f| f.metadata().ok())
            .map(|m| m.len())
            .sum()
    }

    pub fn remove(&self, name: &str) {
        if is_name(name) {
            let _ = fs::remove_file(self.path(name));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dedupes_by_content() {
        let dir = std::env::temp_dir().join(format!("wm-media-{}", std::process::id()));
        let store = MediaStore::new(&dir);
        let a = store.put(b"\x89PNG....", "png").unwrap();
        let b = store.put(b"\x89PNG....", "png").unwrap();
        assert_eq!(a, b);
        assert!(store.contains(&a));
        assert_eq!(ext_for("", b"\xFF\xD8\xFF\xE0"), "jpg");
        assert_eq!(ext_for("image/webp; q=1", b""), "webp");
        let streamed = store.put_reader(&b"\x89PNG...."[..], "").unwrap();
        assert_eq!(streamed, a); // same hash streamed or in one piece
        assert!(store.bytes() > 0);
        assert!(is_name(&a));
        for bad in ["../../etc/passwd", "/tmp/x.jpg", "ab/cd.jpg", "0123456789abcdef0123456789abcdef.JPG", "x.jpg", ""] {
            assert!(!is_name(bad), "{bad}");
            assert!(!store.contains(bad));
        }
        let _ = fs::remove_dir_all(dir);
    }
}
