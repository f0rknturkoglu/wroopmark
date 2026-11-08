//! The single frame every saved thing is normalized into, whatever platform
//! it came from.

use serde::{Deserialize, Serialize};
use serde_json::Value;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
#[derive(Default)]
pub enum Platform {
    X,
    Facebook,
    Tiktok,
    Pinterest,
    Reddit,
    Youtube,
    Instagram,
    Github,
    Hackernews,
    Arxiv,
    #[default]
    Web,
}

impl Platform {
    pub const ALL: [Platform; 11] = [
        Self::X,
        Self::Facebook,
        Self::Tiktok,
        Self::Pinterest,
        Self::Reddit,
        Self::Youtube,
        Self::Instagram,
        Self::Github,
        Self::Hackernews,
        Self::Arxiv,
        Self::Web,
    ];

    pub fn as_str(self) -> &'static str {
        match self {
            Self::X => "x",
            Self::Facebook => "facebook",
            Self::Tiktok => "tiktok",
            Self::Pinterest => "pinterest",
            Self::Reddit => "reddit",
            Self::Youtube => "youtube",
            Self::Instagram => "instagram",
            Self::Github => "github",
            Self::Hackernews => "hackernews",
            Self::Arxiv => "arxiv",
            Self::Web => "web",
        }
    }

    /// Accepts the canonical names plus the aliases people actually type.
    pub fn parse(s: &str) -> Option<Self> {
        Some(match s.to_ascii_lowercase().as_str() {
            "x" | "twitter" | "tw" | "tweet" => Self::X,
            "facebook" | "fb" => Self::Facebook,
            "tiktok" | "tt" => Self::Tiktok,
            "pinterest" | "pin" => Self::Pinterest,
            "reddit" | "rd" => Self::Reddit,
            "youtube" | "yt" => Self::Youtube,
            "instagram" | "ig" | "insta" => Self::Instagram,
            "github" | "gh" => Self::Github,
            "hackernews" | "hn" | "ycombinator" => Self::Hackernews,
            "arxiv" => Self::Arxiv,
            "web" | "custom" | "link" => Self::Web,
            _ => return None,
        })
    }

    pub fn from_host(host: &str) -> Self {
        let h = host.trim_start_matches("www.").trim_start_matches("m.").trim_start_matches("mobile.");
        let is = |d: &str| h == d || h.ends_with(&format!(".{d}"));
        if is("x.com") || is("twitter.com") {
            Self::X
        } else if is("facebook.com") || is("fb.com") || is("fb.watch") {
            Self::Facebook
        } else if is("tiktok.com") {
            Self::Tiktok
        } else if is("pin.it") || h.split('.').any(|p| p == "pinterest") {
            Self::Pinterest
        } else if is("reddit.com") || is("redd.it") {
            Self::Reddit
        } else if is("youtube.com") || is("youtu.be") {
            Self::Youtube
        } else if is("instagram.com") {
            Self::Instagram
        } else if is("github.com") {
            Self::Github
        } else if is("news.ycombinator.com") || is("lobste.rs") {
            Self::Hackernews
        } else if is("arxiv.org") {
            Self::Arxiv
        } else {
            Self::Web
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum MediaKind {
    Image,
    Video,
    Gif,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Media {
    pub kind: MediaKind,
    /// Remote URL: the image itself, or the best video file.
    pub url: String,
    /// Remote poster image for videos.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub thumb_url: Option<String>,
    /// Local file in the media store (`<xxh3>.<ext>`): the image, or the
    /// video's poster. `None` until downloaded.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub file: Option<String>,
    /// Local copy of the video itself (`<xxh3>.mp4`), when downloaded.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub video_file: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub width: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub height: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub alt: Option<String>,
}

impl Media {
    pub fn image(url: impl Into<String>) -> Self {
        Self { kind: MediaKind::Image, url: url.into(), thumb_url: None, file: None, video_file: None, width: None, height: None, alt: None }
    }

    /// A video whose file can be fetched directly (X's mp4 variants). TikTok
    /// only gives a page URL, which needs the site's cookies to play.
    pub fn downloadable_video(&self) -> Option<&str> {
        if self.kind == MediaKind::Image {
            return None;
        }
        let path = self.url.split(['?', '#']).next().unwrap_or("");
        path.ends_with(".mp4").then_some(self.url.as_str())
    }

    /// The URL whose bytes end up in `file`.
    pub fn local_source(&self) -> &str {
        match self.kind {
            MediaKind::Image => &self.url,
            _ => self.thumb_url.as_deref().unwrap_or(""),
        }
    }
}

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct Item {
    /// Deterministic: `x:<id>`, `tiktok:<id>`, `pinterest:<id>`, `web:<hash>`.
    /// The same post saved on two devices gets the same id.
    #[serde(default)]
    pub id: String,
    #[serde(default)]
    pub platform: Platform,
    pub url: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub author_handle: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub author_name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub author_avatar: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    #[serde(default)]
    pub text: String,
    /// Search-only text: article body, OCR output. Not shown as the post text.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub extra: Option<String>,
    /// Text recognized in the pictures (OCR by the app); search and detail.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ocr: Option<String>,
    /// When the post was published (unix seconds).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub created_at: Option<i64>,
    /// When it entered the library (unix seconds); set by the store.
    #[serde(default)]
    pub saved_at: i64,
    #[serde(default)]
    pub media: Vec<Media>,
    /// Outbound links found in the post (already expanded, not normalized).
    #[serde(default)]
    pub links: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub quote: Option<Box<Item>>,
    #[serde(default)]
    pub tags: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub note: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub folder_id: Option<i64>,
    #[serde(default)]
    pub video_tries: i64,
    /// Original payload, kept (zstd) so items can be re-parsed later.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub raw: Option<Value>,
}

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct Folder {
    pub id: i64,
    pub name: String,
    #[serde(default)]
    pub count: i64,
    #[serde(default)]
    pub created_at: i64,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct Link {
    pub id: i64,
    pub url: String,
    pub host: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub image: Option<String>,
    pub first_seen: i64,
    /// Added by hand rather than found in a post.
    pub manual: bool,
    /// How many saved items contain it.
    pub item_count: i64,
    /// The last check found the page gone (404, 410, or no such host).
    #[serde(default)]
    pub dead: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub status: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub checked_at: Option<i64>,
}
