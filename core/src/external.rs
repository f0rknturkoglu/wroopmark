//! Outside downloaders, for videos the core cannot fetch by itself: TikTok
//! hands its files only to clients that pass its bot check, which yt-dlp
//! does with curl_cffi's browser impersonation. Tried in order: yt-dlp,
//! then gallery-dl. Neither ships with wroopmark; they are found where uv,
//! pipx and Homebrew install them.

use std::fs::{self, File};
use std::io::{BufRead, BufReader, Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use url::Url;

pub type ProgressCallback = Arc<dyn Fn(f32, Option<&str>, Option<&str>) + Send + Sync>;

#[derive(Debug, thiserror::Error)]
pub enum ExternalError {
    #[error("geçersiz URL")]
    InvalidUrl,
    #[error("yt-dlp ya da gallery-dl kurulu değil")]
    NoToolInstalled,
    #[error("çalışma dizini hazırlanamadı: {0}")]
    WorkDir(#[source] std::io::Error),
    #[error("PATH oluşturulamadı: {0}")]
    PathEnv(#[source] std::env::JoinPathsError),
    #[error("{0}: günlük dosyası açılamadı: {1}")]
    LogCreate(&'static str, #[source] std::io::Error),
    #[error("{0}: başlatılamadı: {1}")]
    Spawn(&'static str, #[source] std::io::Error),
    #[error("{0}: süreç izlenemedi: {1}")]
    Wait(&'static str, #[source] std::io::Error),
    #[error("{0}: zaman aşımı")]
    Timeout(&'static str),
    #[error("{0}: durduruldu")]
    Cancelled(&'static str),
    #[error("{0}: {1}")]
    Failed(&'static str, String),
    #[error("dizin okunamadı: {0}")]
    ReadDir(#[source] std::io::Error),
    #[error("{0}")]
    Multiple(String),
}

/// Parses yt-dlp's `"[download]  45.2% of  12.34MiB at  2.50MiB/s ETA 00:03"` line.
pub fn parse_progress(line: &str) -> Option<(f32, Option<&str>, Option<&str>)> {
    if !line.contains("[download]") || !line.contains('%') {
        return None;
    }
    let mut pct = None;
    let mut speed = None;
    let mut eta = None;
    let mut it = line.split_whitespace().peekable();
    while let Some(p) = it.next() {
        if let Some(num) = p.strip_suffix('%') {
            if let Ok(val) = num.parse::<f32>() {
                pct = Some(val);
            }
        } else if p == "at" {
            if let Some(&val) = it.peek() {
                speed = Some(val);
            }
        } else if p == "ETA"
            && let Some(&val) = it.peek()
        {
            eta = Some(val);
        }
    }
    pct.map(|p| (p, speed, eta))
}

/// Validates that `url` is a clean `http://` or `https://` URL before passing it
/// to an external binary, preventing argument injection (`-` prefix) or odd schemes.
fn validate_url(url: &str) -> Result<&str, ExternalError> {
    let trimmed = url.trim();
    if trimmed.is_empty() || trimmed.starts_with('-') || trimmed.chars().any(char::is_control) {
        return Err(ExternalError::InvalidUrl);
    }
    let parsed = Url::parse(trimmed).map_err(|_| ExternalError::InvalidUrl)?;
    if !matches!(parsed.scheme(), "http" | "https") || parsed.host_str().is_none() {
        return Err(ExternalError::InvalidUrl);
    }
    Ok(trimmed)
}

/// One video may take this long (large files on a slow line).
const TIMEOUT: Duration = Duration::from_secs(300);

/// Maximum stderr tail read when diagnosing an external downloader failure.
const MAX_LOG_TAIL_BYTES: u64 = 16 * 1024;

/// HEVC up to 1080p first: about a fifth the size of TikTok's H.264 file at
/// the same resolution, and AVFoundation plays it. Then any mp4, then
/// whatever is best.
const YTDLP_FORMAT: &str = "b[vcodec^=bytevc1][height<=1080]/b[vcodec^=h265][height<=1080]/b[vcodec^=hevc][height<=1080]/b[ext=mp4]/b";

#[derive(Debug, Clone, Copy, PartialEq, serde::Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum Tool {
    YtDlp,
    GalleryDl,
}

impl Tool {
    pub const ALL: [Tool; 2] = [Tool::YtDlp, Tool::GalleryDl];

    pub fn name(self) -> &'static str {
        match self {
            Tool::YtDlp => "yt-dlp",
            Tool::GalleryDl => "gallery-dl",
        }
    }

    fn args(self, dir: &Path, url: &str) -> Vec<String> {
        let dir = dir.to_string_lossy();
        let owned = |v: &[&str]| v.iter().map(|a| a.to_string()).collect::<Vec<_>>();
        match self {
            Tool::YtDlp => {
                let mut a = owned(&["--no-playlist", "--no-warnings", "--newline"]);
                a.extend(owned(&["--socket-timeout", "30", "-f", YTDLP_FORMAT, "-o"]));
                a.push(format!("{dir}/video.%(ext)s"));
                a.push("--".into());
                a.push(url.into());
                a
            }
            Tool::GalleryDl => {
                let mut a = owned(&["-q", "--no-part", "-D"]);
                a.push(dir.into_owned());
                a.extend(owned(&["-f", "video.{extension}", "--", url]));
                a
            }
        }
    }
}

/// Folders searched besides `$PATH`: an app started from the Dock gets a
/// bare PATH without them.
fn search_dirs() -> Vec<PathBuf> {
    let mut dirs: Vec<PathBuf> = std::env::var_os("PATH").map(|p| std::env::split_paths(&p).collect()).unwrap_or_default();
    if let Some(home) = std::env::var_os("HOME").map(PathBuf::from) {
        dirs.push(home.join(".local/bin"));
        dirs.push(home.join("bin"));
    }
    dirs.push("/opt/homebrew/bin".into());
    dirs.push("/usr/local/bin".into());
    dirs
}

/// Where a tool is installed, if it is.
pub fn find(tool: Tool) -> Option<PathBuf> {
    search_dirs().into_iter().map(|d| d.join(tool.name())).find(|p| p.is_file())
}

/// Installed tools, in the order they are tried.
pub fn available() -> Vec<(Tool, PathBuf)> {
    Tool::ALL.into_iter().filter_map(|t| find(t).map(|p| (t, p))).collect()
}

/// Guarantees no zombie child process or detached stdout-reader thread can
/// survive early returns, timeouts, or cancellation.
struct ChildGuard {
    child: Child,
    progress: Option<JoinHandle<()>>,
    reaped: bool,
}

impl ChildGuard {
    fn join_progress(&mut self) {
        if let Some(handle) = self.progress.take() {
            let _ = handle.join();
        }
    }
}

impl Drop for ChildGuard {
    fn drop(&mut self) {
        if !self.reaped {
            let _ = self.child.kill();
            let _ = self.child.wait();
            self.reaped = true;
        }
        self.join_progress();
    }
}

fn read_log_tail(path: &Path) -> String {
    let Ok(mut f) = File::open(path) else {
        return String::new();
    };
    let Ok(len) = f.metadata().map(|m| m.len()) else {
        return String::new();
    };
    if len > MAX_LOG_TAIL_BYTES {
        let _ = f.seek(SeekFrom::End(-(MAX_LOG_TAIL_BYTES as i64)));
    }
    let mut buf = Vec::with_capacity(len.min(MAX_LOG_TAIL_BYTES) as usize);
    let _ = f.take(MAX_LOG_TAIL_BYTES).read_to_end(&mut buf);
    String::from_utf8_lossy(&buf).into_owned()
}

/// Runs one tool into `dir` and returns the file it wrote.
fn run(tool: Tool, exe: &Path, dir: &Path, url: &str, on_progress: Option<&ProgressCallback>, stop: &AtomicBool) -> Result<PathBuf, ExternalError> {
    let log = dir.join(format!("{}.log", tool.name()));
    let stderr = File::create(&log).map_err(|e| ExternalError::LogCreate(tool.name(), e))?;
    // The tools find their own helpers (deno for yt-dlp's JS challenges)
    // next to them and in the usual places.
    let path = std::env::join_paths(std::iter::once(exe.parent().unwrap_or(Path::new("/")).to_path_buf()).chain(search_dirs()))
        .map_err(ExternalError::PathEnv)?;
    let mut child = Command::new(exe)
        .args(tool.args(dir, url))
        .env("PATH", path)
        .stdin(Stdio::null())
        .stdout(if on_progress.is_some() { Stdio::piped() } else { Stdio::null() })
        .stderr(stderr)
        .spawn()
        .map_err(|e| ExternalError::Spawn(tool.name(), e))?;

    let progress_thread = child.stdout.take().map(|out| {
        let cb = on_progress.cloned();
        std::thread::spawn(move || {
            let mut reader = BufReader::new(out);
            let mut line = String::with_capacity(256);
            loop {
                line.clear();
                match reader.read_line(&mut line) {
                    Ok(0) | Err(_) => break,
                    Ok(_) => {
                        if let Some(cb) = &cb
                            && let Some((pct, spd, eta)) = parse_progress(&line)
                        {
                            cb(pct, spd, eta);
                        }
                        if line.capacity() > 4096 {
                            line = String::with_capacity(256);
                        }
                    }
                }
            }
        })
    });

    let mut guard = ChildGuard { child, progress: progress_thread, reaped: false };
    let start = Instant::now();
    let status = loop {
        if stop.load(Ordering::Acquire) {
            return Err(ExternalError::Cancelled(tool.name()));
        }
        if let Some(s) = guard.child.try_wait().map_err(|e| ExternalError::Wait(tool.name(), e))? {
            guard.reaped = true;
            break s;
        }
        if start.elapsed() > TIMEOUT {
            return Err(ExternalError::Timeout(tool.name()));
        }
        std::thread::sleep(Duration::from_millis(250));
    };

    guard.join_progress();

    let file = fs::read_dir(dir)
        .map_err(ExternalError::ReadDir)?
        .flatten()
        .filter(|e| e.file_type().is_ok_and(|t| t.is_file()))
        .map(|e| e.path())
        .filter(|p| p.file_name().is_some_and(|n| n.to_string_lossy().starts_with("video.")))
        .filter(|p| !p.extension().is_some_and(|e| e == "part" || e == "ytdl"))
        .max_by_key(|p| fs::metadata(p).map(|m| m.len()).unwrap_or(0));
    match file {
        Some(f) if status.success() => Ok(f),
        _ => {
            let msg = read_log_tail(&log);
            let last = msg.lines().rev().find(|l| !l.trim().is_empty()).unwrap_or("dosya yok").trim();
            Err(ExternalError::Failed(tool.name(), last.chars().take(200).collect()))
        }
    }
}

/// Downloads a post's video with the first tool that manages it, into a
/// fresh folder under `work`. The caller moves the file away and removes
/// the folder.
pub fn download_with_progress(url: &str, work: &Path, on_progress: Option<&ProgressCallback>, stop: &AtomicBool) -> Result<PathBuf, ExternalError> {
    let url = validate_url(url)?;
    let tools = available();
    if tools.is_empty() {
        return Err(ExternalError::NoToolInstalled);
    }
    let mut errors = Vec::new();
    for (tool, exe) in tools {
        if stop.load(Ordering::Acquire) {
            return Err(ExternalError::Cancelled(tool.name()));
        }
        let _ = fs::remove_dir_all(work);
        fs::create_dir_all(work).map_err(ExternalError::WorkDir)?;
        match run(tool, &exe, work, url, on_progress, stop) {
            Ok(f) => return Ok(f),
            Err(ExternalError::Cancelled(name)) => return Err(ExternalError::Cancelled(name)),
            Err(e) => errors.push(e.to_string()),
        }
    }
    Err(ExternalError::Multiple(errors.join("; ")))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn arguments_and_validation() {
        let a = Tool::YtDlp.args(Path::new("/w"), "https://t/v");
        assert_eq!(a[a.len() - 4..], ["-o".to_string(), "/w/video.%(ext)s".into(), "--".into(), "https://t/v".into()]);
        let g = Tool::GalleryDl.args(Path::new("/w"), "https://t/v");
        assert_eq!(g[3], "/w");
        assert_eq!(g[g.len() - 2..], ["--".to_string(), "https://t/v".into()]);
        assert!(matches!(validate_url("--exec=rm"), Err(ExternalError::InvalidUrl)));
        assert!(matches!(validate_url("file:///etc/passwd"), Err(ExternalError::InvalidUrl)));
        assert!(matches!(validate_url("https://example.com/v\n--bad"), Err(ExternalError::InvalidUrl)));
        assert_eq!(validate_url(" https://tiktok.com/@u/video/1 ").ok(), Some("https://tiktok.com/@u/video/1"));
    }

    #[test]
    fn progress_parsing() {
        assert_eq!(parse_progress("[download]  45.2% of  12.34MiB at  2.50MiB/s ETA 00:03"), Some((45.2, Some("2.50MiB/s"), Some("00:03"))));
        assert_eq!(parse_progress("[download] Destination: out.mp4"), None);
        assert_eq!(parse_progress("[download] 100% at"), Some((100.0, None, None)));
    }
}
