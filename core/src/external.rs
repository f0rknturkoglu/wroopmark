//! Outside downloaders, for videos the core cannot fetch by itself: TikTok
//! hands its files only to clients that pass its bot check, which yt-dlp
//! does with curl_cffi's browser impersonation. Tried in order: yt-dlp,
//! then gallery-dl. Neither ships with wroopmark; they are found where uv,
//! pipx and Homebrew install them.

use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::Arc;
use std::time::{Duration, Instant};

pub type ProgressCallback = Arc<dyn Fn(f32, Option<&str>, Option<&str>) + Send + Sync>;

/// Parses yt-dlp's "[download]  45.2% of  12.34MiB at  2.50MiB/s ETA 00:03" line.
pub fn parse_progress(line: &str) -> Option<(f32, Option<String>, Option<String>)> {
    if !line.contains("[download]") || !line.contains('%') {
        return None;
    }
    let parts: Vec<&str> = line.split_whitespace().collect();
    let mut pct = None;
    let mut speed = None;
    let mut eta = None;
    for (i, p) in parts.iter().enumerate() {
        if p.ends_with('%') {
            if let Ok(val) = p.trim_end_matches('%').parse::<f32>() {
                pct = Some(val);
            }
        } else if *p == "at" && i + 1 < parts.len() {
            speed = Some(parts[i + 1].to_string());
        } else if *p == "ETA" && i + 1 < parts.len() {
            eta = Some(parts[i + 1].to_string());
        }
    }
    pct.map(|p| (p, speed, eta))
}

/// One video may take this long (large files on a slow line).
const TIMEOUT: Duration = Duration::from_secs(300);

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
                a.push(url.into());
                a
            }
            Tool::GalleryDl => {
                let mut a = owned(&["-q", "--no-part", "-D"]);
                a.push(dir.into_owned());
                a.extend(owned(&["-f", "video.{extension}", url]));
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

/// Runs one tool into `dir` and returns the file it wrote.
fn run(tool: Tool, exe: &Path, dir: &Path, url: &str, on_progress: Option<&ProgressCallback>) -> Result<PathBuf, String> {
    let log = dir.join(format!("{}.log", tool.name()));
    let stderr = fs::File::create(&log).map_err(|e| e.to_string())?;
    // The tools find their own helpers (deno for yt-dlp's JS challenges)
    // next to them and in the usual places.
    let path = std::env::join_paths(std::iter::once(exe.parent().unwrap_or(Path::new("/")).to_path_buf()).chain(search_dirs()))
        .map_err(|e| e.to_string())?;
    let mut child = Command::new(exe)
        .args(tool.args(dir, url))
        .env("PATH", path)
        .stdin(Stdio::null())
        .stdout(if on_progress.is_some() { Stdio::piped() } else { Stdio::null() })
        .stderr(stderr)
        .spawn()
        .map_err(|e| format!("{}: başlatılamadı: {e}", tool.name()))?;

    let progress_thread = child.stdout.take().map(|out| {
        let cb = on_progress.cloned();
        std::thread::spawn(move || {
            use std::io::{BufRead, BufReader};
            let reader = BufReader::new(out);
            for line in reader.lines().map_while(Result::ok) {
                if let Some(cb) = &cb
                    && let Some((pct, spd, eta)) = parse_progress(&line)
                {
                    cb(pct, spd.as_deref(), eta.as_deref());
                }
            }
        })
    });

    let start = Instant::now();
    let status = loop {
        if let Some(s) = child.try_wait().map_err(|e| e.to_string())? {
            break s;
        }
        if start.elapsed() > TIMEOUT {
            let _ = child.kill();
            let _ = child.wait();
            return Err(format!("{}: zaman aşımı", tool.name()));
        }
        std::thread::sleep(Duration::from_millis(250));
    };

    if let Some(handle) = progress_thread {
        let _ = handle.join();
    }

    let file = fs::read_dir(dir)
        .map_err(|e| e.to_string())?
        .flatten()
        .map(|e| e.path())
        .filter(|p| p.file_name().is_some_and(|n| n.to_string_lossy().starts_with("video.")))
        .filter(|p| !p.extension().is_some_and(|e| e == "part" || e == "ytdl"))
        .max_by_key(|p| fs::metadata(p).map(|m| m.len()).unwrap_or(0));
    match file {
        Some(f) if status.success() => Ok(f),
        _ => {
            let msg = fs::read_to_string(&log).unwrap_or_default();
            let last = msg.lines().rev().find(|l| !l.trim().is_empty()).unwrap_or("dosya yok").trim();
            Err(format!("{}: {}", tool.name(), last.chars().take(200).collect::<String>()))
        }
    }
}

/// Downloads a post's video with the first tool that manages it, into a
/// fresh folder under `work`. The caller moves the file away and removes
/// the folder.
pub fn download(url: &str, work: &Path) -> Result<PathBuf, String> {
    download_with_progress(url, work, None)
}

pub fn download_with_progress(url: &str, work: &Path, on_progress: Option<&ProgressCallback>) -> Result<PathBuf, String> {
    let tools = available();
    if tools.is_empty() {
        return Err("yt-dlp ya da gallery-dl kurulu değil".into());
    }
    let mut errors = vec![];
    for (tool, exe) in tools {
        let _ = fs::remove_dir_all(work);
        fs::create_dir_all(work).map_err(|e| e.to_string())?;
        match run(tool, &exe, work, url, on_progress) {
            Ok(f) => return Ok(f),
            Err(e) => errors.push(e),
        }
    }
    Err(errors.join("; "))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn arguments() {
        let a = Tool::YtDlp.args(Path::new("/w"), "https://t/v");
        assert_eq!(a[a.len() - 3..], ["-o".to_string(), "/w/video.%(ext)s".into(), "https://t/v".into()]);
        let g = Tool::GalleryDl.args(Path::new("/w"), "https://t/v");
        assert_eq!(g[3], "/w");
    }
}
