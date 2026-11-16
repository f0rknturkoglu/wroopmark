//! On-device intelligence: meaning search vectors and summaries.
//!
//! The models are the system's own (NaturalLanguage's `NLContextualEmbedding`
//! and Foundation Models), reached through `wroopmark-ai`, a small Swift
//! helper next to the CLI in `Contents/Helpers`. It runs only while there is
//! work and quits by itself after a minute of quiet, so the model memory is
//! never held by the app or the core.
//!
//! Vectors are stored as int8 with one f32 scale (≈ 0.5 KB per item for a
//! 512-dimension model) and compared by brute force: a few thousand dot
//! products is far below a millisecond.

use std::ffi::{CStr, CString, c_char, c_void};
use std::io::{BufRead, BufReader, Write};
use std::path::PathBuf;
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::mpsc::{Receiver, RecvTimeoutError, channel};
use std::sync::{Mutex, OnceLock};
use std::time::Duration;

use base64::Engine;
use base64::engine::general_purpose::STANDARD as B64;
use serde_json::{Value, json};

use crate::model::Item;

#[derive(Debug, thiserror::Error)]
pub enum AiError {
    #[error("cihazdaki zeka yardımcısı bulunamadı (wroopmark-ai)")]
    NoHelper,
    #[error("zeka yardımcısı: {0}")]
    Helper(String),
    #[error("zeka yardımcısı yanıt vermedi")]
    Timeout,
    #[error("{0}")]
    Io(#[from] std::io::Error),
    #[error("{0}")]
    Json(#[from] serde_json::Error),
}

// --- Vectors -------------------------------------------------------------------

/// Unit-normalizes and packs a vector: 4-byte little-endian scale, then one
/// signed byte per dimension.
pub fn encode(v: &[f32]) -> Option<Vec<u8>> {
    let norm = v.iter().map(|x| x * x).sum::<f32>().sqrt();
    if !norm.is_finite() || norm <= f32::EPSILON {
        return None;
    }
    let max = v.iter().map(|x| (x / norm).abs()).fold(0.0f32, f32::max);
    if max <= f32::EPSILON {
        return None;
    }
    let scale = max / 127.0;
    let mut out = Vec::with_capacity(4 + v.len());
    out.extend_from_slice(&scale.to_le_bytes());
    for x in v {
        let q = ((x / norm) / scale).round().clamp(-127.0, 127.0) as i8;
        out.push(q as u8);
    }
    Some(out)
}

fn parts(b: &[u8]) -> Option<(f32, &[u8])> {
    let (head, body) = b.split_at_checked(4)?;
    let scale = f32::from_le_bytes(head.try_into().ok()?);
    Some((scale, body))
}

/// Cosine similarity of two packed vectors (0 when they do not fit).
pub fn cosine(a: &[u8], b: &[u8]) -> f32 {
    let (Some((sa, qa)), Some((sb, qb))) = (parts(a), parts(b)) else { return 0.0 };
    if qa.len() != qb.len() {
        return 0.0;
    }
    let dot: i32 = qa.iter().zip(qb).map(|(&x, &y)| i32::from(x as i8) * i32::from(y as i8)).sum();
    dot as f32 * sa * sb
}

/// Unpacks to floats (scale × value); empty when it does not parse.
pub fn unpack(b: &[u8]) -> Vec<f32> {
    parts(b).map(|(s, q)| q.iter().map(|&x| f32::from(x as i8) * s).collect()).unwrap_or_default()
}

/// The library's vectors, centered on their mean and re-normalized.
///
/// Mean-pooled sentence vectors all lean the same way (every pair scores
/// 0.7+); taking the shared direction out spreads them so a score says
/// something. Built per query: a few MB for tens of thousands of items,
/// freed right after.
pub struct Space {
    pks: Vec<i64>,
    dim: usize,
    vecs: Vec<f32>,
    mean: Vec<f32>,
}

fn normalize(v: &mut [f32]) {
    let n = v.iter().map(|x| x * x).sum::<f32>().sqrt();
    if n > f32::EPSILON {
        v.iter_mut().for_each(|x| *x /= n);
    }
}

impl Space {
    pub fn new(rows: &[(i64, Vec<u8>)]) -> Self {
        let dim = rows.iter().map(|(_, v)| unpack(v).len()).find(|&d| d > 0).unwrap_or(0);
        let mut pks = vec![];
        let mut vecs = vec![];
        let mut mean = vec![0.0f32; dim];
        for (pk, v) in rows {
            let f = unpack(v);
            if f.len() != dim || dim == 0 {
                continue;
            }
            mean.iter_mut().zip(&f).for_each(|(m, x)| *m += x);
            pks.push(*pk);
            vecs.extend(f);
        }
        if !pks.is_empty() {
            let n = pks.len() as f32;
            mean.iter_mut().for_each(|m| *m /= n);
        }
        for chunk in vecs.chunks_exact_mut(dim.max(1)) {
            chunk.iter_mut().zip(&mean).for_each(|(x, m)| *x -= m);
            normalize(chunk);
        }
        Self { pks, dim, vecs, mean }
    }

    pub fn len(&self) -> usize {
        self.pks.len()
    }

    pub fn is_empty(&self) -> bool {
        self.pks.is_empty()
    }

    fn center(&self, packed: &[u8]) -> Option<Vec<f32>> {
        let mut q = unpack(packed);
        if q.len() != self.dim || self.dim == 0 {
            return None;
        }
        q.iter_mut().zip(&self.mean).for_each(|(x, m)| *x -= m);
        normalize(&mut q);
        Some(q)
    }

    fn row(&self, i: usize) -> &[f32] {
        self.vecs.get(i * self.dim..(i + 1) * self.dim).unwrap_or(&[])
    }

    /// The `k` items closest to `query` (centered cosine), best first.
    pub fn nearest(&self, query: &[u8], k: usize, skip: Option<i64>) -> Vec<(i64, f32)> {
        let Some(q) = self.center(query) else { return vec![] };
        let mut scored: Vec<(i64, f32)> = self
            .pks
            .iter()
            .enumerate()
            .filter(|(_, pk)| Some(**pk) != skip)
            .map(|(i, pk)| (*pk, self.row(i).iter().zip(&q).map(|(a, b)| a * b).sum::<f32>()))
            .collect();
        scored.sort_by(|a, b| b.1.total_cmp(&a.1));
        scored.truncate(k);
        scored
    }

    /// Pairs at least `threshold` alike (centered cosine), each pair once.
    pub fn pairs(&self, threshold: f32) -> Vec<(i64, i64)> {
        let mut out = vec![];
        for i in 0..self.pks.len() {
            let a = self.row(i);
            for j in i + 1..self.pks.len() {
                let s: f32 = a.iter().zip(self.row(j)).map(|(x, y)| x * y).sum();
                if s >= threshold
                    && let (Some(pa), Some(pb)) = (self.pks.get(i), self.pks.get(j))
                {
                    out.push((*pa, *pb));
                }
            }
        }
        out
    }
}

/// The `k` rows closest to `query`, best first.
pub fn nearest(query: &[u8], rows: &[(i64, Vec<u8>)], k: usize, skip: Option<i64>) -> Vec<(i64, f32)> {
    let mut scored: Vec<(i64, f32)> = rows.iter().filter(|(pk, _)| Some(*pk) != skip).map(|(pk, v)| (*pk, cosine(query, v))).collect();
    scored.sort_by(|a, b| b.1.total_cmp(&a.1));
    scored.truncate(k);
    scored
}

/// Reciprocal rank fusion: items high in either list come first.
pub fn fuse(lists: &[&[i64]]) -> Vec<i64> {
    fuse_weighted(&lists.iter().map(|l| (*l, 1.0)).collect::<Vec<_>>())
}

/// Like [`fuse`], trusting some lists more than others.
pub fn fuse_weighted(lists: &[(&[i64], f32)]) -> Vec<i64> {
    let mut score: std::collections::HashMap<i64, f32> = std::collections::HashMap::new();
    for (list, weight) in lists {
        for (rank, pk) in list.iter().enumerate() {
            *score.entry(*pk).or_default() += weight / (60.0 + rank as f32);
        }
    }
    let mut out: Vec<(i64, f32)> = score.into_iter().collect();
    out.sort_by(|a, b| b.1.total_cmp(&a.1).then(a.0.cmp(&b.0)));
    out.into_iter().map(|(pk, _)| pk).collect()
}

/// Pairs of rows at least `threshold` alike (each pair once).
pub fn near_pairs(rows: &[(i64, Vec<u8>)], threshold: f32) -> Vec<(i64, i64)> {
    let mut out = vec![];
    for (i, (pa, va)) in rows.iter().enumerate() {
        for (pb, vb) in rows.iter().skip(i + 1) {
            if cosine(va, vb) >= threshold {
                out.push((*pa, *pb));
            }
        }
    }
    out
}

/// What the embedding sees of an item: its words, not its metadata.
pub fn embed_text(item: &Item) -> String {
    let mut parts: Vec<&str> = vec![];
    if let Some(t) = item.title.as_deref() {
        parts.push(t);
    }
    parts.push(&item.text);
    if let Some(q) = item.quote.as_deref() {
        parts.push(&q.text);
    }
    for t in &item.thread {
        parts.push(&t.text);
    }
    if let Some(n) = item.note.as_deref() {
        parts.push(n);
    }
    if let Some(o) = item.ocr.as_deref() {
        parts.push(o);
    }
    if let Some(e) = item.extra.as_deref() {
        parts.push(e);
    }
    let joined = parts.into_iter().map(str::trim).filter(|s| !s.is_empty()).collect::<Vec<_>>().join("\n");
    // A word or two ("lol", a caption made of hashtags) carries no meaning
    // to match on; such items get no vector rather than a vague one that
    // would come up for every search.
    let letters = joined
        .split_whitespace()
        .filter(|w| !w.starts_with('#') && !w.starts_with('@') && !w.starts_with("http"))
        .map(|w| w.chars().filter(|c| c.is_alphabetic()).count())
        .sum::<usize>();
    if letters < 25 {
        return String::new();
    }
    joined.chars().take(1200).collect()
}

/// The embedding model's id and one packed vector per text (`None` where
/// the model gave nothing).
pub type Embedded = (String, Vec<Option<Vec<u8>>>);

// --- Helper process -----------------------------------------------------------

pub type AiOutFn = unsafe extern "C" fn(*mut c_void, *const c_char);
pub type AiCallback = unsafe extern "C" fn(*const c_char, *mut c_void, AiOutFn);

static CALLBACK: OnceLock<AiCallback> = OnceLock::new();

pub fn set_callback(f: Option<AiCallback>) {
    if let Some(f) = f {
        let _ = CALLBACK.set(f);
    }
}

pub fn has_callback() -> bool {
    CALLBACK.get().is_some()
}

struct Proc {
    child: Child,
    stdin: ChildStdin,
    lines: Receiver<String>,
}

impl Drop for Proc {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

/// One `wroopmark-ai` process, started on first use and restarted when it
/// has quit (it does after a minute without requests).
#[derive(Default)]
pub struct Helper {
    proc: Mutex<Option<Proc>>,
}

impl Helper {
    /// `$WROOPMARK_AI`, else next to this executable or in the app bundle.
    pub fn path() -> Option<PathBuf> {
        if let Some(p) = std::env::var_os("WROOPMARK_AI").map(PathBuf::from).filter(|p| p.is_file()) {
            return Some(p);
        }
        let exe = std::env::current_exe().ok().and_then(|p| p.canonicalize().ok());
        let mut candidates = vec![];
        if let Some(dir) = exe.as_ref().and_then(|e| e.parent()) {
            candidates.push(dir.join("wroopmark-ai"));
            candidates.push(dir.join("../Helpers/wroopmark-ai"));
        }
        candidates.push(PathBuf::from("/Applications/wroopmark.app/Contents/Helpers/wroopmark-ai"));
        candidates.into_iter().find(|p| p.is_file())
    }

    fn spawn() -> Result<Proc, AiError> {
        let path = Self::path().ok_or(AiError::NoHelper)?;
        let mut child = Command::new(path).stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::null()).spawn()?;
        let stdin = child.stdin.take().ok_or(AiError::NoHelper)?;
        let stdout = child.stdout.take().ok_or(AiError::NoHelper)?;
        let (tx, rx) = channel();
        std::thread::spawn(move || {
            for line in BufReader::new(stdout).lines() {
                let Ok(line) = line else { break };
                if tx.send(line).is_err() {
                    break;
                }
            }
        });
        Ok(Proc { child, stdin, lines: rx })
    }

    /// Sends one request line and waits for its answer line.
    pub fn request(&self, req: &Value, timeout: Duration) -> Result<Value, AiError> {
        unsafe extern "C" fn take_reply(ctx: *mut c_void, json: *const c_char) {
            if !ctx.is_null() && !json.is_null() {
                // SAFETY: ctx points to `Option<String>` on the caller's stack; json is valid for this call.
                let slot = unsafe { &mut *ctx.cast::<Option<String>>() };
                // SAFETY: caller guarantees json is a valid NUL-terminated C string.
                *slot = Some(unsafe { CStr::from_ptr(json) }.to_string_lossy().into_owned());
            }
        }
        let mut slot = self.proc.lock().map_err(|_| AiError::Helper("kilit bozuldu".into()))?;
        let line = serde_json::to_string(req)?;
        if let Some(&cb) = CALLBACK.get() {
            let clean = if line.as_bytes().contains(&0) { line.replace('\0', " ") } else { line };
            let c_req = CString::new(clean).map_err(|_| AiError::Helper("geçersiz istek".into()))?;
            let mut answer: Option<String> = None;
            // SAFETY: c_req is a valid C string and answer lives on this stack frame for the duration of cb.
            unsafe { cb(c_req.as_ptr(), (&raw mut answer).cast(), take_reply) };
            let raw = answer.ok_or_else(|| AiError::Helper("yanıt yok".into()))?;
            let v: Value = serde_json::from_str(&raw)?;
            if let Some(e) = v.get("error").and_then(Value::as_str) {
                return Err(AiError::Helper(e.to_string()));
            }
            return Ok(v);
        }
        for attempt in 0..2 {
            if slot.as_mut().is_none_or(|p| p.child.try_wait().ok().flatten().is_some()) {
                *slot = Some(Self::spawn()?);
            }
            let Some(p) = slot.as_mut() else { return Err(AiError::NoHelper) };
            let sent = writeln!(p.stdin, "{line}").and_then(|_| p.stdin.flush());
            if sent.is_err() {
                *slot = None;
                continue;
            }
            match p.lines.recv_timeout(timeout) {
                Ok(answer) => {
                    let v: Value = serde_json::from_str(&answer)?;
                    if let Some(e) = v.get("error").and_then(Value::as_str) {
                        return Err(AiError::Helper(e.to_string()));
                    }
                    return Ok(v);
                }
                Err(RecvTimeoutError::Timeout) => {
                    *slot = None;
                    return Err(AiError::Timeout);
                }
                // It quit between requests (idle) — start it again once.
                Err(RecvTimeoutError::Disconnected) if attempt == 0 => *slot = None,
                Err(RecvTimeoutError::Disconnected) => break,
            }
        }
        Err(AiError::Helper("yardımcı kapandı".into()))
    }

    /// Embeds texts in one go. Returns the model id and one packed vector
    /// per text (`None` where the model gave nothing).
    pub fn embed(&self, texts: &[String]) -> Result<Embedded, AiError> {
        let v = self.request(&json!({"op": "embed", "texts": texts}), Duration::from_secs(120))?;
        let model = v.get("model").and_then(Value::as_str).unwrap_or("").to_string();
        let vecs = v
            .get("vecs")
            .and_then(Value::as_array)
            .map(|a| a.iter().map(|x| x.as_str().and_then(|s| B64.decode(s).ok()).and_then(|b| encode(&floats(&b)))).collect())
            .unwrap_or_default();
        Ok((model, vecs))
    }

    /// A short summary and tag ideas, preferring tags the library has.
    pub fn summarize(&self, text: &str, known_tags: &[String]) -> Result<(String, Vec<String>), AiError> {
        let v = self.request(&json!({"op": "summarize", "text": text, "tags": known_tags}), Duration::from_secs(90))?;
        let summary = v.get("summary").and_then(Value::as_str).unwrap_or("").trim().to_string();
        let tags =
            v.get("tags").and_then(Value::as_array).map(|a| a.iter().filter_map(Value::as_str).map(str::to_string).collect()).unwrap_or_default();
        Ok((summary, tags))
    }

    /// Related search words for a query (synonyms, both languages).
    pub fn expand(&self, query: &str) -> Result<Vec<String>, AiError> {
        let v = self.request(&json!({"op": "expand", "query": query}), Duration::from_secs(30))?;
        Ok(v.get("terms").and_then(Value::as_array).map(|a| a.iter().filter_map(Value::as_str).map(str::to_string).collect()).unwrap_or_default())
    }

    /// What the models on this Mac can do right now.
    pub fn status(&self) -> Value {
        match self.request(&json!({"op": "status"}), Duration::from_secs(60)) {
            Ok(v) => v,
            Err(e) => json!({"embed": false, "llm": e.to_string(), "error": e.to_string()}),
        }
    }
}

fn floats(b: &[u8]) -> Vec<f32> {
    b.as_chunks::<4>().0.iter().map(|c| f32::from_le_bytes(*c)).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn packs_and_compares() {
        let a = encode(&[1.0, 0.0, 0.0]).unwrap_or_default();
        let b = encode(&[2.0, 0.1, 0.0]).unwrap_or_default();
        let c = encode(&[0.0, 0.0, 1.0]).unwrap_or_default();
        assert_eq!(a.len(), 7);
        assert!(cosine(&a, &a) > 0.99);
        assert!(cosine(&a, &b) > 0.98);
        assert!(cosine(&a, &c).abs() < 0.01);
        assert!(encode(&[0.0, 0.0]).is_none());
        let rows = vec![(1, a.clone()), (2, b), (3, c)];
        let near = nearest(&a, &rows, 2, Some(1));
        assert_eq!(near.first().map(|n| n.0), Some(2));
        assert_eq!(near_pairs(&rows, 0.97), vec![(1, 2)]);
        assert_eq!(fuse(&[&[1, 2, 3], &[3, 1]]).first(), Some(&1));
    }
}
