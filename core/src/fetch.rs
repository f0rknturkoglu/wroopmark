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

pub type Result<T> = std::result::Result<T, String>;

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

static REFRESH_RE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r#"(?i)http-equiv=["']?refresh["']?[^>]*?content=["']?\d*\s*;\s*url=([^"'>\s]+)"#).expect("refresh regex"));

static META_SEL: LazyLock<Selector> = LazyLock::new(|| Selector::parse("meta[content]").expect("static selector"));
static TITLE_SEL: LazyLock<Selector> = LazyLock::new(|| Selector::parse("title").expect("static selector"));
static PARAS_SELS: LazyLock<[Selector; 3]> = LazyLock::new(|| [
    Selector::parse("article p").expect("static selector"),
    Selector::parse("main p").expect("static selector"),
    Selector::parse("p").expect("static selector"),
]);
static OEMBED_P_SEL: LazyLock<Selector> = LazyLock::new(|| Selector::parse("blockquote > p").expect("static selector"));
static OEMBED_A_SEL: LazyLock<Selector> = LazyLock::new(|| Selector::parse("blockquote > a").expect("static selector"));

fn enc(s: &str) -> String {
    url::form_urlencoded::byte_serialize(s.as_bytes()).collect()
}

pub fn parse_page(final_url: &str, html: &str) -> PageMeta {
    let doc = Html::parse_document(html);
    let base = Url::parse(final_url).ok();
    let mut metas: Vec<(String, String)> = vec![];
    for m in doc.select(&META_SEL) {
        let key = m.value().attr("property").or_else(|| m.value().attr("name")).unwrap_or("").to_ascii_lowercase();
        let content = m.value().attr("content").unwrap_or("").trim();
        if !key.is_empty() && !content.is_empty() {
            metas.push((key, content.to_string()));
        }
    }
    let meta = |keys: &[&str]| keys.iter().find_map(|k| metas.iter().find(|(mk, _)| mk == k).map(|(_, v)| v.clone()));
    let abs = |u: String| base.as_ref().and_then(|b| b.join(&u).ok()).map(|u| u.to_string()).unwrap_or(u);

    let title = meta(&["og:title", "twitter:title"])
        .or_else(|| doc.select(&TITLE_SEL).next().map(|t| tidy(&t.text().collect::<String>())).filter(|t| !t.is_empty()));
    let mut paras: Vec<String> = vec![];
    for sel in &*PARAS_SELS {
        paras = doc.select(sel).map(|p| tidy(&p.text().collect::<String>())).filter(|p| p.len() > 40).collect();
        if !paras.is_empty() {
            break;
        }
    }
    let mut body = paras.join("\n\n");
    if body.len() > MAX_EXTRA_CHARS {
        let cut = (0..=MAX_EXTRA_CHARS).rev().find(|i| body.is_char_boundary(*i)).unwrap_or(0);
        body.truncate(cut);
    }
    PageMeta {
        url: final_url.to_string(),
        title,
        description: meta(&["og:description", "twitter:description", "description"]),
        image: meta(&["og:image:secure_url", "og:image", "twitter:image", "twitter:image:src"]).map(abs),
        author: meta(&["article:author", "author", "twitter:creator", "pinterestapp:pinner"]),
        published: meta(&["article:published_time", "og:published_time", "date"])
            .and_then(|d| chrono::DateTime::parse_from_rfc3339(&d).ok())
            .map(|d| d.timestamp()),
        body: (!body.is_empty()).then_some(body),
        // Read from the raw HTML: these stubs usually sit in <noscript>,
        // which the parser keeps as plain text.
        refresh: REFRESH_RE.captures(html).map(|c| abs(c[1].to_string())),
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
        let config = Agent::config_builder().tls_config(tls).user_agent(UA).timeout_global(Some(Duration::from_secs(25))).max_redirects(8).build();
        Self { agent: config.new_agent() }
    }

    fn get(&self, url: &str) -> Result<ureq::http::Response<ureq::Body>> {
        self.agent.get(url).header("Accept-Language", "tr,en;q=0.8").call().map_err(|e| format!("{url}: {e}"))
    }

    /// Final URL (after redirects) and body text.
    pub fn get_text(&self, url: &str) -> Result<(String, String)> {
        let mut resp = self.get(url)?;
        let final_url = resp.get_uri().to_string();
        let body = resp.body_mut().with_config().limit(MAX_HTML).lossy_utf8(true).read_to_string().map_err(|e| e.to_string())?;
        Ok((final_url, body))
    }

    pub fn get_json(&self, url: &str) -> Result<Value> {
        let (_, body) = self.get_text(url)?;
        serde_json::from_str(&body).map_err(|e| format!("{url}: geçersiz JSON: {e}"))
    }

    pub fn get_bytes(&self, url: &str) -> Result<(Vec<u8>, String)> {
        let mut resp = self.get(url)?;
        let ct = resp.headers().get("content-type").and_then(|v| v.to_str().ok()).unwrap_or("").to_string();
        let bytes = resp.body_mut().with_config().limit(MAX_MEDIA).read_to_vec().map_err(|e| e.to_string())?;
        Ok((bytes, ct))
    }

    pub fn page(&self, url: &str) -> Result<PageMeta> {
        let (final_url, html) = self.get_text(url)?;
        let page = parse_page(&final_url, &html);
        // Static sites that moved often leave a meta-refresh stub behind.
        match (&page.refresh, &page.description) {
            (Some(next), None) if next != &final_url => {
                let (final_url, html) = self.get_text(next)?;
                Ok(parse_page(&final_url, &html))
            }
            _ => Ok(page),
        }
    }

    /// Turns a URL into an item, using the best source per platform.
    pub fn capture(&self, url: &str) -> Result<Item> {
        let url = url.trim();
        if Url::parse(url).map(|u| !matches!(u.scheme(), "http" | "https")).unwrap_or(true) {
            return Err(format!("geçersiz URL: {url}"));
        }
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
        let platform = Platform::from_host(Url::parse(&page.url).ok().and_then(|u| u.host_str().map(str::to_string)).as_deref().unwrap_or(""));
        if platform == Platform::Facebook && page.description.is_none() {
            return Err("Facebook bu gönderiyi giriş yapmadan göstermiyor; tarayıcı eklentisiyle kaydet".into());
        }
        let text = page.description.clone().unwrap_or_default();
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
        let html = v.get("html").and_then(Value::as_str).ok_or("X oEmbed boş döndü (silinmiş ya da gizli olabilir)")?;
        let doc = Html::parse_fragment(html);
        let text = doc.select(&OEMBED_P_SEL).next().map(|p| tidy(&p.text().collect::<String>())).unwrap_or_default();
        let created_at = doc
            .select(&OEMBED_A_SEL)
            .next_back()
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
        crate::tiktok::parse_video_page(&html)
            .ok_or_else(|| format!("TikTok sayfası okunamadı ({final_url}); gizli/silinmiş olabilir ya da eklentiyle kaydet"))
    }

    pub fn download(&self, store: &MediaStore, url: &str) -> Result<String> {
        let (bytes, ct) = self.get_bytes(url)?;
        if bytes.is_empty() {
            return Err(format!("{url}: boş yanıt"));
        }
        store.put(&bytes, ext_for(&ct, &bytes)).map_err(|e| e.to_string())
    }

    /// Streams a video to the media store.
    pub fn download_video(&self, store: &MediaStore, url: &str) -> Result<String> {
        // The agent's 25 s budget covers the whole body; videos get minutes.
        let mut resp =
            self.agent.get(url).config().timeout_global(Some(Duration::from_secs(600))).build().call().map_err(|e| format!("{url}: {e}"))?;
        let ct = resp.headers().get("content-type").and_then(|v| v.to_str().ok()).unwrap_or("").to_string();
        let reader = resp.body_mut().with_config().limit(MAX_VIDEO).reader();
        store.put_reader(reader, &ct).map_err(|e| format!("{url}: {e}"))
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
    }
}
