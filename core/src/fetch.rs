//! Network capture for plain URLs (share sheet, paste, CLI) and media
//! downloads. Posts captured by the extensions never come through here.
//!
//! - X:        `publish.twitter.com/oembed` (text + author, no images)
//! - TikTok:   `tiktok.com/oembed` (caption, author, cover)
//! - the rest: OpenGraph tags + article text from the page itself

use std::sync::LazyLock;
use std::time::Duration;

use regex::Regex;

use scraper::{Html, Selector};
use serde_json::Value;
use ureq::{Agent, ResponseExt};
use url::Url;

use crate::media::{MediaStore, ext_for};
use crate::model::{Item, Media, Platform};
use crate::text::{extract_urls, item_id_for_url, normalize_url, tidy};

const UA: &str = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15";
const MAX_HTML: u64 = 4 << 20;
const MAX_MEDIA: u64 = 30 << 20;
const MAX_VIDEO: u64 = 600 << 20;
const MAX_EXTRA_CHARS: usize = 20_000;

pub type Result<T> = std::result::Result<T, FetchError>;

#[derive(Debug, thiserror::Error)]
pub enum FetchError {
    #[error("geçersiz URL: {0}")]
    InvalidUrl(String),
    #[error("{url}: {source}")]
    Http {
        url: String,
        #[source]
        source: Box<ureq::Error>,
    },
    #[error("{url}: yanıt okunamadı: {source}")]
    ReadBody {
        url: String,
        #[source]
        source: Box<ureq::Error>,
    },
    #[error("{url}: geçersiz JSON: {source}")]
    InvalidJson {
        url: String,
        #[source]
        source: serde_json::Error,
    },
    #[error("{0}: boş yanıt")]
    EmptyBody(String),
    #[error("{url}: {source}")]
    MediaStore {
        url: String,
        #[source]
        source: std::io::Error,
    },
    #[error("{url}: video boyut sınırını aşıyor ({size} bayt)")]
    TooLarge { url: String, size: u64 },
    #[error("Facebook bu gönderiyi giriş yapmadan göstermiyor; tarayıcı eklentisiyle kaydet")]
    FacebookLoginRequired,
    #[error("X oEmbed boş döndü (silinmiş ya da gizli olabilir)")]
    XEmptyOembed,
    #[error("TikTok sayfası okunamadı ({0}); gizli/silinmiş olabilir ya da eklentiyle kaydet")]
    TiktokUnreadable(String),
}

pub struct Fetcher {
    agent: Agent,
}

/// What a page says about itself.
#[derive(Debug, Default)]
pub struct PageMeta {
    pub url: String,
    pub title: Option<String>,
    pub description: Option<String>,
    pub image: Option<String>,
    pub author: Option<String>,
    pub published: Option<i64>,
    pub body: Option<String>,
    /// `<meta http-equiv="refresh" content="0; url=…">` target.
    pub refresh: Option<String>,
}

static REFRESH_RE: LazyLock<Option<Regex>> =
    LazyLock::new(|| Regex::new(r#"(?i-u:http-equiv)=["']?(?i-u:refresh)["']?[^>]*?(?i-u:content)=["']?\d*\s*;\s*(?i-u:url)=([^"'>\s]+)"#).ok());

static META_SEL: LazyLock<Option<Selector>> = LazyLock::new(|| Selector::parse("meta[content]").ok());
static TITLE_SEL: LazyLock<Option<Selector>> = LazyLock::new(|| Selector::parse("title").ok());
static PARAS_SELS: LazyLock<[Option<Selector>; 3]> =
    LazyLock::new(|| [Selector::parse("article p").ok(), Selector::parse("main p").ok(), Selector::parse("p").ok()]);
static OEMBED_P_SEL: LazyLock<Option<Selector>> = LazyLock::new(|| Selector::parse("blockquote > p").ok());
static OEMBED_A_SEL: LazyLock<Option<Selector>> = LazyLock::new(|| Selector::parse("blockquote > a").ok());

fn enc(s: &str) -> String {
    url::form_urlencoded::byte_serialize(s.as_bytes()).collect()
}

fn pick_slot<'a, const N: usize>(slots: &mut [Option<&'a str>; N], keys: [&str; N], key: &str, val: &'a str) {
    for (slot, candidate) in slots.iter_mut().zip(keys) {
        if slot.is_none() && key.eq_ignore_ascii_case(candidate) {
            *slot = Some(val);
            break;
        }
    }
}

fn validate_http_url(url: &str) -> Result<&str> {
    let trimmed = url.trim();
    match Url::parse(trimmed) {
        Ok(u) if matches!(u.scheme(), "http" | "https") && u.host_str().is_some() => Ok(trimmed),
        _ => Err(FetchError::InvalidUrl(url.to_string())),
    }
}

pub fn parse_page(final_url: &str, html: &str) -> PageMeta {
    let doc = Html::parse_document(html);
    let base = Url::parse(final_url).ok();
    let abs = |u: &str| base.as_ref().and_then(|b| b.join(u).ok()).map(String::from).unwrap_or_else(|| u.to_string());

    let mut title_slots: [Option<&str>; 2] = [None; 2];
    let mut desc_slots: [Option<&str>; 3] = [None; 3];
    let mut img_slots: [Option<&str>; 4] = [None; 4];
    let mut author_slots: [Option<&str>; 4] = [None; 4];
    let mut pub_slots: [Option<&str>; 3] = [None; 3];

    if let Some(meta_sel) = META_SEL.as_ref() {
        for m in doc.select(meta_sel) {
            let Some(key) = m.value().attr("property").or_else(|| m.value().attr("name")).map(str::trim).filter(|k| !k.is_empty()) else {
                continue;
            };
            let Some(content) = m.value().attr("content").map(str::trim).filter(|c| !c.is_empty()) else {
                continue;
            };
            pick_slot(&mut title_slots, ["og:title", "twitter:title"], key, content);
            pick_slot(&mut desc_slots, ["og:description", "twitter:description", "description"], key, content);
            pick_slot(&mut img_slots, ["og:image:secure_url", "og:image", "twitter:image", "twitter:image:src"], key, content);
            pick_slot(&mut author_slots, ["article:author", "author", "twitter:creator", "pinterestapp:pinner"], key, content);
            pick_slot(&mut pub_slots, ["article:published_time", "og:published_time", "date"], key, content);
        }
    }

    let title =
        title_slots.into_iter().flatten().next().map(str::to_string).or_else(|| {
            TITLE_SEL.as_ref().and_then(|sel| doc.select(sel).next()).map(|t| tidy(&t.text().collect::<String>())).filter(|t| !t.is_empty())
        });

    let mut body = String::new();
    let mut raw_para = String::new();
    for sel in PARAS_SELS.iter().flatten() {
        for p in doc.select(sel) {
            raw_para.clear();
            for chunk in p.text() {
                raw_para.push_str(chunk);
            }
            let cleaned = tidy(&raw_para);
            if cleaned.len() > 40 {
                if !body.is_empty() {
                    body.push_str("\n\n");
                }
                body.push_str(&cleaned);
                if body.len() >= MAX_EXTRA_CHARS {
                    break;
                }
            }
        }
        if !body.is_empty() {
            break;
        }
    }
    drop(raw_para);

    let description = desc_slots.into_iter().flatten().next().map(str::to_string);
    let image = img_slots.into_iter().flatten().next().map(abs);
    let author = author_slots.into_iter().flatten().next().map(str::to_string);
    let published = pub_slots.into_iter().flatten().next().and_then(|d| chrono::DateTime::parse_from_rfc3339(d).ok()).map(|d| d.timestamp());
    drop(doc);

    if body.len() > MAX_EXTRA_CHARS {
        let cut = (0..=MAX_EXTRA_CHARS).rev().find(|i| body.is_char_boundary(*i)).unwrap_or(0);
        body.truncate(cut);
        if body.capacity() > body.len() + 1024 {
            body.shrink_to_fit();
        }
    }

    PageMeta {
        url: final_url.to_string(),
        title,
        description,
        image,
        author,
        published,
        body: (!body.is_empty()).then_some(body),
        // Read from the raw HTML: these stubs usually sit in <noscript>,
        // which the parser keeps as plain text.
        refresh: REFRESH_RE.as_ref().and_then(|re| re.captures(html)).and_then(|c| c.get(1)).map(|m| abs(m.as_str())),
    }
}

impl Default for Fetcher {
    fn default() -> Self {
        Self::new()
    }
}

impl Fetcher {
    pub fn new() -> Self {
        let tls =
            ureq::tls::TlsConfig::builder().provider(ureq::tls::TlsProvider::NativeTls).root_certs(ureq::tls::RootCerts::PlatformVerifier).build();
        let config = Agent::config_builder()
            .tls_config(tls)
            .user_agent(UA)
            .timeout_resolve(Some(Duration::from_secs(5)))
            .timeout_connect(Some(Duration::from_secs(8)))
            .timeout_send_request(Some(Duration::from_secs(5)))
            .timeout_recv_response(Some(Duration::from_secs(12)))
            .timeout_recv_body(Some(Duration::from_secs(20)))
            .timeout_per_read(Some(Duration::from_secs(10)))
            .timeout_global(Some(Duration::from_secs(25)))
            .max_idle_connections(16)
            .max_idle_connections_per_host(4)
            .max_idle_age(Duration::from_secs(30))
            .max_response_header_size(64 * 1024)
            .max_redirects(8)
            .build();
        Self { agent: config.new_agent() }
    }

    fn get(&self, url: &str) -> Result<ureq::http::Response<ureq::Body>> {
        let url = validate_http_url(url)?;
        self.agent
            .get(url)
            .header("Accept-Language", "tr,en;q=0.8")
            .call()
            .map_err(|e| FetchError::Http { url: url.to_string(), source: Box::new(e) })
    }

    /// Final URL (after redirects) and body text.
    pub fn get_text(&self, url: &str) -> Result<(String, String)> {
        let mut resp = self.get(url)?;
        let final_url = resp.get_uri().to_string();
        let body = resp
            .body_mut()
            .with_config()
            .limit(MAX_HTML)
            .lossy_utf8(true)
            .read_to_string()
            .map_err(|e| FetchError::ReadBody { url: final_url.clone(), source: Box::new(e) })?;
        Ok((final_url, body))
    }

    pub fn get_json(&self, url: &str) -> Result<Value> {
        let (_, body) = self.get_text(url)?;
        serde_json::from_str(&body).map_err(|e| FetchError::InvalidJson { url: url.to_string(), source: e })
    }

    pub fn get_bytes(&self, url: &str) -> Result<(Vec<u8>, String)> {
        let mut resp = self.get(url)?;
        let ct = resp.headers().get("content-type").and_then(|v| v.to_str().ok()).unwrap_or("").to_string();
        let bytes = resp
            .body_mut()
            .with_config()
            .limit(MAX_MEDIA)
            .read_to_vec()
            .map_err(|e| FetchError::ReadBody { url: url.to_string(), source: Box::new(e) })?;
        Ok((bytes, ct))
    }

    /// Whether a link still opens: `(status, dead)`. Status 0 means the host
    /// did not answer. Only a missing page (404, 410) or an unknown host
    /// counts as dead; blocks (403, 429) and timeouts say nothing.
    pub fn check(&self, url: &str) -> (i64, bool) {
        let Ok(url) = validate_http_url(url) else {
            return (0, false);
        };
        let call = self
            .agent
            .get(url)
            .config()
            .timeout_connect(Some(Duration::from_secs(5)))
            .timeout_global(Some(Duration::from_secs(10)))
            .build()
            .header("Accept-Language", "tr,en;q=0.8")
            .call();
        match call {
            Ok(r) => (i64::from(r.status().as_u16()), false),
            Err(ureq::Error::StatusCode(code)) => (i64::from(code), matches!(code, 404 | 410)),
            Err(ureq::Error::HostNotFound) => (0, true),
            Err(_) => (0, false),
        }
    }

    pub fn page(&self, url: &str) -> Result<PageMeta> {
        let page = {
            let (final_url, html) = self.get_text(url)?;
            parse_page(&final_url, &html)
        };
        // Static sites that moved often leave a meta-refresh stub behind.
        if let Some(next) = page.refresh.as_deref()
            && page.description.is_none()
            && next != page.url
        {
            let (final_url, html) = self.get_text(next)?;
            return Ok(parse_page(&final_url, &html));
        }
        Ok(page)
    }

    /// Turns a URL into an item, using the best source per platform.
    pub fn capture(&self, url: &str) -> Result<Item> {
        let url = validate_http_url(url)?;
        let (platform, _) = item_id_for_url(url);
        let mut item = match platform {
            Platform::X => self.x_oembed(url)?,
            Platform::Tiktok => self.tiktok(url)?,
            _ => self.generic(url)?,
        };
        // Redirects (pin.it, vm.tiktok.com, t.co) settle on the real post.
        item.url = normalize_url(&item.url).unwrap_or(item.url);
        let (platform, id) = item_id_for_url(&item.url);
        item.platform = platform;
        item.id = id;
        Ok(item)
    }

    fn generic(&self, url: &str) -> Result<Item> {
        let page = self.page(url)?;
        let parsed_url = Url::parse(&page.url).ok();
        let platform = Platform::from_host(parsed_url.as_ref().and_then(|u| u.host_str()).unwrap_or(""));
        if platform == Platform::Facebook && page.description.is_none() {
            return Err(FetchError::FacebookLoginRequired);
        }
        let text = page.description.unwrap_or_default();
        let extra = page.body.filter(|b| b.len() > text.len() + 40);
        // Pinterest and others name the author by profile URL.
        let (author_handle, author_name) = match page.author {
            Some(a) if a.starts_with("http") => (a.trim_end_matches('/').rsplit('/').next().map(|h| h.trim_start_matches('@').to_string()), None),
            other => (None, other),
        };
        Ok(Item {
            platform,
            url: page.url,
            author_handle,
            author_name,
            title: page.title,
            links: extract_urls(&text),
            text,
            extra,
            created_at: page.published,
            media: page.image.into_iter().map(Media::image).collect(),
            ..Default::default()
        })
    }

    fn x_oembed(&self, url: &str) -> Result<Item> {
        let v = self.get_json(&format!("https://publish.twitter.com/oembed?omit_script=1&dnt=true&url={}", enc(url)))?;
        let html = v.get("html").and_then(Value::as_str).ok_or(FetchError::XEmptyOembed)?;
        let doc = Html::parse_fragment(html);
        let text = OEMBED_P_SEL.as_ref().and_then(|sel| doc.select(sel).next()).map(|p| tidy(&p.text().collect::<String>())).unwrap_or_default();
        let created_at = OEMBED_A_SEL
            .as_ref()
            .and_then(|sel| doc.select(sel).next_back())
            .and_then(|a| chrono::NaiveDate::parse_from_str(&a.text().collect::<String>(), "%B %d, %Y").ok())
            .and_then(|d| d.and_hms_opt(12, 0, 0))
            .map(|d| d.and_utc().timestamp());
        let handle = v.get("author_url").and_then(Value::as_str).and_then(|u| u.rsplit('/').next()).map(str::to_string);
        Ok(Item {
            platform: Platform::X,
            url: v.get("url").and_then(Value::as_str).unwrap_or(url).to_string(),
            author_handle: handle,
            author_name: v.get("author_name").and_then(Value::as_str).map(str::to_string),
            links: extract_urls(&text).into_iter().filter(|l| !l.contains("pic.twitter.com")).collect(),
            text,
            created_at,
            raw: Some(v),
            ..Default::default()
        })
    }

    fn tiktok(&self, url: &str) -> Result<Item> {
        // The video page embeds the full item (oEmbed only returns the id
        // these days); short links (vm./vt.tiktok.com) redirect to it.
        let (final_url, html) = self.get_text(url)?;
        crate::tiktok::parse_video_page(&html).ok_or(FetchError::TiktokUnreadable(final_url))
    }

    pub fn download(&self, store: &MediaStore, url: &str) -> Result<String> {
        let (bytes, ct) = self.get_bytes(url)?;
        if bytes.is_empty() {
            return Err(FetchError::EmptyBody(url.to_string()));
        }
        store.put(&bytes, ext_for(&ct, &bytes)).map_err(|source| FetchError::MediaStore { url: url.to_string(), source })
    }

    /// Streams a video to the media store.
    pub fn download_video(&self, store: &MediaStore, url: &str) -> Result<String> {
        let url = validate_http_url(url)?;
        // The agent's 25 s budget covers the whole body; videos get minutes,
        // while stalled reads still abort after 30 s.
        let mut resp = self
            .agent
            .get(url)
            .config()
            .timeout_recv_body(Some(Duration::from_secs(600)))
            .timeout_per_read(Some(Duration::from_secs(30)))
            .timeout_global(Some(Duration::from_secs(600)))
            .build()
            .call()
            .map_err(|e| FetchError::Http { url: url.to_string(), source: Box::new(e) })?;
        if let Some(cl) = resp.headers().get("content-length").and_then(|v| v.to_str().ok()).and_then(|s| s.parse::<u64>().ok())
            && cl > MAX_VIDEO
        {
            return Err(FetchError::TooLarge { url: url.to_string(), size: cl });
        }
        let ct = resp.headers().get("content-type").and_then(|v| v.to_str().ok()).unwrap_or("").to_string();
        let reader = resp.body_mut().with_config().limit(MAX_VIDEO).reader();
        store.put_reader(reader, &ct).map_err(|source| FetchError::MediaStore { url: url.to_string(), source })
    }

    /// Downloads every image / video poster not yet on disk, and with
    /// `videos` the videos themselves. Returns how many files were fetched;
    /// failures are left for a later retry.
    pub fn fill_media(&self, store: &MediaStore, media: &mut [Media], videos: bool) -> usize {
        let mut n = 0;
        for m in media.iter_mut() {
            let src = m.local_source().to_string();
            if m.file.is_none()
                && !src.is_empty()
                && let Ok(name) = self.download(store, &src)
            {
                m.file = Some(name);
                n += 1;
            }
            if videos
                && m.video_file.is_none()
                && let Some(url) = m.downloadable_video().map(str::to_string)
                && let Ok(name) = self.download_video(store, &url)
            {
                m.video_file = Some(name);
                n += 1;
            }
        }
        n
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_open_graph() {
        assert!(REFRESH_RE.is_some());
        assert!(META_SEL.is_some());
        assert!(TITLE_SEL.is_some());
        assert!(PARAS_SELS.iter().all(Option::is_some));
        assert!(OEMBED_P_SEL.is_some());
        assert!(OEMBED_A_SEL.is_some());

        let html = r#"<html><head><title>Fallback</title>
            <meta property="og:title" content="Başlık">
            <meta name="description" content="Kısa açıklama">
            <meta property="og:image" content="/img/a.png">
            <meta property="article:published_time" content="2025-03-01T10:00:00Z">
            </head><body><article><p>Bu paragraf yeterince uzun olmalı ki makale gövdesi olarak sayılsın, değil mi?</p></article></body></html>"#;
        let m = parse_page("https://example.com/post/1", html);
        assert_eq!(m.title.as_deref(), Some("Başlık"));
        assert_eq!(m.description.as_deref(), Some("Kısa açıklama"));
        assert_eq!(m.image.as_deref(), Some("https://example.com/img/a.png"));
        assert_eq!(m.published, Some(1740823200));
        assert!(m.body.unwrap().starts_with("Bu paragraf"));

        let f = Fetcher::new();
        assert!(matches!(f.capture("file:///etc/passwd"), Err(FetchError::InvalidUrl(_))));
        assert!(matches!(f.download_video(&MediaStore::new("/tmp"), "ftp://x.com/a.mp4"), Err(FetchError::InvalidUrl(_))));
    }
}
