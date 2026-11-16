//! Export formats: Markdown (one note per item, Obsidian-friendly YAML front
//! matter, media next to it) and CSV (one row per item).

use std::collections::HashSet;

use chrono::DateTime;

use crate::model::{Highlight, Item};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Format {
    Markdown,
    Csv,
    Json,
    /// One page with everything inside, to send to someone.
    Html,
}

impl Format {
    pub fn parse(s: &str) -> Option<Self> {
        match s.trim().to_ascii_lowercase().as_str() {
            "md" | "markdown" | "obsidian" => Some(Self::Markdown),
            "csv" => Some(Self::Csv),
            "json" | "jsonl" => Some(Self::Json),
            "html" | "htm" => Some(Self::Html),
            _ => None,
        }
    }
}

fn date(ts: Option<i64>) -> String {
    ts.and_then(|t| DateTime::from_timestamp(t, 0)).map(|d| d.format("%Y-%m-%d").to_string()).unwrap_or_default()
}

fn datetime(ts: Option<i64>) -> String {
    ts.and_then(|t| DateTime::from_timestamp(t, 0)).map(|d| d.format("%Y-%m-%dT%H:%M:%SZ").to_string()).unwrap_or_default()
}

/// A YAML double-quoted scalar.
fn yq(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    out.push('"');
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => {}
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

/// The item's display title: its title, else the start of its text.
pub fn title_of(item: &Item) -> String {
    let base = item.title.as_deref().filter(|t| !t.trim().is_empty()).unwrap_or(&item.text);
    let line = base.lines().map(str::trim).find(|l| !l.is_empty()).unwrap_or("");
    let t: String = line.chars().take(80).collect();
    if t.is_empty() {
        item.author_handle.clone().or_else(|| item.author_name.clone()).unwrap_or_else(|| item.platform.as_str().to_string())
    } else {
        t
    }
}

/// A file name safe on every file system: no separators, no control chars,
/// not too long.
pub fn safe_name(s: &str) -> String {
    let cleaned: String = s
        .chars()
        .map(|c| if c.is_control() || matches!(c, '/' | '\\' | ':' | '*' | '?' | '"' | '<' | '>' | '|' | '#' | '[' | ']' | '^') { ' ' } else { c })
        .collect();
    let words: Vec<&str> = cleaned.split_whitespace().collect();
    let mut out = String::new();
    for w in words {
        if out.chars().count() + w.chars().count() > 60 {
            break;
        }
        if !out.is_empty() {
            out.push(' ');
        }
        out.push_str(w);
    }
    let out = out.trim_matches('.').to_string();
    if out.is_empty() { "kayit".into() } else { out }
}

/// Unique `<date> <title>.md` names within one export.
#[derive(Default)]
pub struct Names {
    used: HashSet<String>,
}

impl Names {
    pub fn next(&mut self, item: &Item) -> String {
        let d = date(item.created_at.or(Some(item.saved_at)));
        let base = safe_name(&format!("{d} {}", title_of(item)));
        let mut name = format!("{base}.md");
        let mut n = 2;
        while !self.used.insert(name.to_lowercase()) {
            name = format!("{base} {n}.md");
            n += 1;
        }
        name
    }
}

/// One Markdown note. `media` are the stored files it embeds, written by
/// the caller to `media/`.
pub fn markdown(item: &Item, folder: Option<&str>, highlights: &[Highlight]) -> (String, Vec<String>) {
    let mut s = String::from("---\n");
    s.push_str(&format!("id: {}\n", yq(&item.id)));
    s.push_str(&format!("url: {}\n", yq(&item.url)));
    s.push_str(&format!("platform: {}\n", item.platform.as_str()));
    if let Some(h) = item.author_handle.as_deref() {
        s.push_str(&format!("author: {}\n", yq(&format!("@{h}"))));
    } else if let Some(n) = item.author_name.as_deref() {
        s.push_str(&format!("author: {}\n", yq(n)));
    }
    if item.created_at.is_some() {
        s.push_str(&format!("created: {}\n", datetime(item.created_at)));
    }
    s.push_str(&format!("saved: {}\n", datetime(Some(item.saved_at))));
    if !item.tags.is_empty() {
        s.push_str("tags:\n");
        for t in &item.tags {
            // Obsidian tags cannot hold spaces.
            s.push_str(&format!("  - {}\n", yq(&t.replace(' ', "-"))));
        }
    }
    if let Some(f) = folder {
        s.push_str(&format!("folder: {}\n", yq(f)));
    }
    s.push_str("source: wroopmark\n---\n\n");

    if let Some(t) = item.title.as_deref().filter(|t| !t.trim().is_empty()) {
        s.push_str(&format!("# {}\n\n", t.trim()));
    }
    if let Some(sum) = item.summary.as_deref().filter(|t| !t.trim().is_empty()) {
        s.push_str(&format!("> [!summary] Özet\n> {}\n\n", sum.trim().replace('\n', "\n> ")));
    }
    if !item.text.trim().is_empty() {
        s.push_str(item.text.trim());
        s.push_str("\n\n");
    }
    for t in &item.thread {
        if !t.text.trim().is_empty() {
            s.push_str(t.text.trim());
            s.push_str("\n\n");
        }
    }
    let mut files = vec![];
    for m in &item.media {
        if let Some(v) = m.video_file.as_deref() {
            s.push_str(&format!("![](media/{v})\n"));
            files.push(v.to_string());
        } else if let Some(f) = m.file.as_deref() {
            s.push_str(&format!("![{}](media/{f})\n", m.alt.as_deref().unwrap_or("").replace(['[', ']', '\n'], " ")));
            files.push(f.to_string());
        }
    }
    if !files.is_empty() {
        s.push('\n');
    }
    if let Some(q) = item.quote.as_deref() {
        let who = q.author_handle.as_deref().map(|h| format!("@{h}")).unwrap_or_default();
        s.push_str(&format!("> **{who}** {}\n", q.text.trim().replace('\n', "\n> ")));
        s.push_str(&format!("> {}\n\n", q.url));
    }
    if !highlights.is_empty() {
        s.push_str("## Vurgular\n\n");
        for h in highlights {
            s.push_str(&format!("> {}\n", h.quote.trim().replace('\n', "\n> ")));
            if let Some(n) = h.note.as_deref().map(str::trim).filter(|n| !n.is_empty()) {
                s.push_str(&format!("- Not: {n}\n"));
            }
            s.push('\n');
        }
    }
    if !item.replies.is_empty() {
        s.push_str("## Yanıtlar\n\n");
        for r in &item.replies {
            let who = r.author_handle.as_deref().map(|h| format!("@{h}")).or_else(|| r.author_name.clone()).unwrap_or_else(|| "…".into());
            let body = r.text.trim();
            if body.is_empty() {
                continue;
            }
            s.push_str(&format!("**{who}**: {body}\n\n"));
        }
    }
    if let Some(n) = item.note.as_deref().filter(|n| !n.trim().is_empty()) {
        s.push_str(&format!("## Not\n\n{}\n\n", n.trim()));
    }
    if !item.links.is_empty() {
        s.push_str("## Bağlantılar\n\n");
        for l in &item.links {
            s.push_str(&format!("- <{l}>\n"));
        }
        s.push('\n');
    }
    s.push_str(&format!("[Kaynak]({}) · [wroopmark'ta aç](wroopmark://item/{})\n", item.url, item.id));
    (s, files)
}

fn csv_field(s: &str) -> String {
    if s.contains([',', '"', '\n', '\r']) { format!("\"{}\"", s.replace('"', "\"\"")) } else { s.to_string() }
}

pub const CSV_HEADER: &str = "id,platform,url,author,title,text,tags,folder,note,summary,created_at,saved_at\n";

pub fn csv_row(item: &Item, folder: Option<&str>) -> String {
    let author = item.author_handle.as_deref().map(|h| format!("@{h}")).or_else(|| item.author_name.clone()).unwrap_or_default();
    let fields = [
        item.id.clone(),
        item.platform.as_str().to_string(),
        item.url.clone(),
        author,
        item.title.clone().unwrap_or_default(),
        item.text.clone(),
        item.tags.join("|"),
        folder.unwrap_or("").to_string(),
        item.note.clone().unwrap_or_default(),
        item.summary.clone().unwrap_or_default(),
        datetime(item.created_at),
        datetime(Some(item.saved_at)),
    ];
    let mut row = fields.iter().map(|f| csv_field(f)).collect::<Vec<_>>().join(",");
    row.push('\n');
    row
}

// --- One HTML page ---------------------------------------------------------------

fn esc(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        match c {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&quot;"),
            '\'' => out.push_str("&#39;"),
            c => out.push(c),
        }
    }
    out
}

/// The page's words in Turkish or English.
struct Words {
    lang: &'static str,
    search: &'static str,
    items: &'static str,
    source: &'static str,
    video: &'static str,
    note: &'static str,
    summary: &'static str,
    highlights: &'static str,
    replies: &'static str,
    made: &'static str,
    none: &'static str,
}

const TR: Words = Words {
    lang: "tr",
    search: "Bu sayfada ara",
    items: "kayıt",
    source: "Kaynak",
    video: "Videoyu kaynağında aç",
    note: "Not",
    summary: "Özet",
    highlights: "Vurgular",
    replies: "Yanıtlar",
    made: "wroopmark ile çevrimdışı arşivden",
    none: "Eşleşen kayıt yok",
};

const EN: Words = Words {
    lang: "en",
    search: "Search this page",
    items: "items",
    source: "Source",
    video: "Open the video at its source",
    note: "Note",
    summary: "Summary",
    highlights: "Highlights",
    replies: "Replies",
    made: "From an offline wroopmark archive",
    none: "No matching items",
};

const PAGE_CSS: &str = r#":root{--bg:#f7f6f3;--card:#fff;--text:#1d1c1a;--muted:#6b6862;--line:#e6e3dd;--accent:#784be3}
@media (prefers-color-scheme:dark){:root{--bg:#141414;--card:#1e1e1f;--text:#ecebe8;--muted:#9a978f;--line:#2e2e30;--accent:#a184f0}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--text);font:16px/1.55 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif}
header{max-width:720px;margin:0 auto;padding:40px 16px 8px}h1{font-size:28px;line-height:1.2;margin:0 0 4px}
.sub{color:var(--muted);font-size:14px}input{width:100%;margin:20px 0 4px;padding:10px 14px;font:inherit;color:inherit;background:var(--card);border:1px solid var(--line);border-radius:10px}
main{max-width:720px;margin:0 auto;padding:8px 16px 48px}article{background:var(--card);border:1px solid var(--line);border-radius:14px;padding:16px 18px;margin:14px 0}
.meta{display:flex;gap:8px;flex-wrap:wrap;color:var(--muted);font-size:13px;margin-bottom:6px}.who{color:var(--text);font-weight:600}
h2{font-size:18px;margin:4px 0 6px;line-height:1.3}.text{white-space:pre-wrap;overflow-wrap:anywhere}
.media{display:grid;grid-template-columns:repeat(auto-fill,minmax(200px,1fr));gap:6px;margin-top:10px}.media img{width:100%;border-radius:8px;display:block}
.vid{position:relative;display:block}.vid::after{content:"▶";position:absolute;inset:auto auto 10px 10px;background:rgba(0,0,0,.6);color:#fff;border-radius:99px;padding:2px 10px;font-size:13px}
.quote,.box{border-left:3px solid var(--line);padding:4px 0 4px 12px;margin-top:10px;color:var(--muted)}.box b{color:var(--text)}
.tags{margin-top:10px;display:flex;gap:6px;flex-wrap:wrap}.tags span{font-size:12px;color:var(--muted);border:1px solid var(--line);border-radius:99px;padding:1px 8px}
a{color:var(--accent)}.foot{margin-top:10px;font-size:13px}footer{text-align:center;color:var(--muted);font-size:13px;padding-bottom:32px}#none{display:none;color:var(--muted);text-align:center}"#;

const PAGE_JS: &str = r#"const q=document.getElementById('q'),cards=[...document.querySelectorAll('article')],none=document.getElementById('none');
const fold=s=>s.toLocaleLowerCase().normalize('NFD').replace(/[̀-ͯ]/g,'').replace(/ı/g,'i');
cards.forEach(c=>c.dataset.t=fold(c.textContent));
q.addEventListener('input',()=>{const w=fold(q.value).split(/\s+/).filter(Boolean);let n=0;
cards.forEach(c=>{const ok=w.every(x=>c.dataset.t.includes(x));c.hidden=!ok;if(ok)n++});none.style.display=n?'none':'block'});"#;

/// A picture as a `data:` URL, or `None` to leave it out.
pub type Embed<'a> = dyn FnMut(&str) -> Option<String> + 'a;

/// One self-contained page: every item as a card, its pictures inside the
/// file (as far as `embed` allows), a search box; opens offline anywhere.
pub fn html_page(
    title: &str,
    items: &[Item],
    folder_of: &dyn Fn(&Item) -> Option<String>,
    highlights_of: &dyn Fn(&Item) -> Vec<Highlight>,
    english: bool,
    embed: &mut Embed<'_>,
) -> String {
    let w = if english { &EN } else { &TR };
    let mut s = String::with_capacity(64 * 1024);
    s.push_str(&format!(
        "<!doctype html><html lang=\"{}\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><title>{}</title><style>{PAGE_CSS}</style></head><body>",
        w.lang,
        esc(title)
    ));
    s.push_str(&format!(
        "<header><h1>{}</h1><div class=\"sub\">{} {} · {}</div><input id=\"q\" type=\"search\" placeholder=\"{}\" aria-label=\"{}\"></header><main>",
        esc(title),
        items.len(),
        w.items,
        date(Some(crate::text::now())),
        w.search,
        w.search
    ));
    for item in items {
        s.push_str("<article>");
        let who = item.author_handle.as_deref().map(|h| format!("@{h}")).or_else(|| item.author_name.clone()).unwrap_or_default();
        s.push_str(&format!("<div class=\"meta\"><span class=\"who\">{}</span><span>{}</span>", esc(&who), esc(item.platform.as_str())));
        s.push_str(&format!("<span>{}</span>", date(item.created_at.or(Some(item.saved_at)))));
        if let Some(f) = folder_of(item) {
            s.push_str(&format!("<span>{}</span>", esc(&f.replace('/', " › "))));
        }
        s.push_str("</div>");
        if let Some(t) = item.title.as_deref().filter(|t| !t.trim().is_empty()) {
            s.push_str(&format!("<h2>{}</h2>", esc(t.trim())));
        }
        let mut text = item.text.trim().to_string();
        for t in &item.thread {
            if !t.text.trim().is_empty() {
                text.push_str("\n\n");
                text.push_str(t.text.trim());
            }
        }
        if !text.is_empty() {
            s.push_str(&format!("<div class=\"text\">{}</div>", esc(&text)));
        }
        let mut pics = String::new();
        for m in &item.media {
            let Some(src) = m.file.as_deref().and_then(&mut *embed) else { continue };
            let alt = esc(m.alt.as_deref().unwrap_or(""));
            if m.kind == crate::model::MediaKind::Image {
                pics.push_str(&format!("<img loading=\"lazy\" src=\"{src}\" alt=\"{alt}\">"));
            } else {
                pics.push_str(&format!(
                    "<a class=\"vid\" href=\"{}\" title=\"{}\"><img loading=\"lazy\" src=\"{src}\" alt=\"{alt}\"></a>",
                    esc(&item.url),
                    w.video
                ));
            }
        }
        if !pics.is_empty() {
            s.push_str(&format!("<div class=\"media\">{pics}</div>"));
        }
        if let Some(q) = item.quote.as_deref() {
            let who = q.author_handle.as_deref().map(|h| format!("@{h}")).unwrap_or_default();
            s.push_str(&format!("<div class=\"quote\"><b>{}</b> {}</div>", esc(&who), esc(q.text.trim())));
        }
        if let Some(sum) = item.summary.as_deref().filter(|t| !t.trim().is_empty()) {
            s.push_str(&format!("<div class=\"box\"><b>{}:</b> {}</div>", w.summary, esc(sum.trim())));
        }
        let hl = highlights_of(item);
        if !hl.is_empty() {
            let parts: Vec<String> = hl
                .iter()
                .map(|h| match h.note.as_deref().map(str::trim).filter(|n| !n.is_empty()) {
                    Some(n) => format!("“{}” — <i>{}</i>", esc(h.quote.trim()), esc(n)),
                    None => format!("“{}”", esc(h.quote.trim())),
                })
                .collect();
            s.push_str(&format!("<div class=\"box\"><b>{}:</b> {}</div>", w.highlights, parts.join("<br>")));
        }
        if !item.replies.is_empty() {
            let parts: Vec<String> = item
                .replies
                .iter()
                .filter(|r| !r.text.trim().is_empty())
                .map(|r| {
                    let who = r.author_handle.as_deref().map(|h| format!("@{h}")).or_else(|| r.author_name.clone()).unwrap_or_default();
                    format!("<b>{}</b> {}", esc(&who), esc(r.text.trim()))
                })
                .collect();
            if !parts.is_empty() {
                s.push_str(&format!("<div class=\"box\"><b>{}:</b> {}</div>", w.replies, parts.join("<br>")));
            }
        }
        if let Some(n) = item.note.as_deref().filter(|n| !n.trim().is_empty()) {
            s.push_str(&format!("<div class=\"box\"><b>{}:</b> {}</div>", w.note, esc(n.trim())));
        }
        if !item.tags.is_empty() {
            s.push_str("<div class=\"tags\">");
            for t in &item.tags {
                s.push_str(&format!("<span>#{}</span>", esc(t)));
            }
            s.push_str("</div>");
        }
        if item.url.starts_with("http") {
            s.push_str(&format!("<div class=\"foot\"><a href=\"{}\" rel=\"noopener\">{} ↗</a></div>", esc(&item.url), w.source));
        }
        s.push_str("</article>");
    }
    s.push_str(&format!("<p id=\"none\">{}</p></main><footer>{}</footer><script>{PAGE_JS}</script></body></html>", w.none, w.made));
    s
}

/// The `data:` type of a stored picture.
pub fn image_type(name: &str) -> Option<&'static str> {
    let ext = name.rsplit('.').next()?.to_ascii_lowercase();
    Some(match ext.as_str() {
        "jpg" | "jpeg" => "image/jpeg",
        "png" => "image/png",
        "gif" => "image/gif",
        "webp" => "image/webp",
        "heic" => "image/heic",
        "avif" => "image/avif",
        _ => return None,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::{Media, Platform};

    #[test]
    fn writes_markdown_and_csv() {
        let mut m = Media::image("https://x/a.jpg");
        m.file = Some("ab12.jpg".into());
        let item = Item {
            id: "x:1".into(),
            platform: Platform::X,
            url: "https://x.com/a/status/1".into(),
            author_handle: Some("a".into()),
            text: "Merhaba \"dünya\"\nikinci satır".into(),
            tags: vec!["dev/rust".into(), "iki kelime".into()],
            media: vec![m],
            saved_at: 1_700_000_000,
            ..Default::default()
        };
        let (md, files) = markdown(
            &Item { replies: vec![Item { author_handle: Some("b".into()), text: "haklısın".into(), ..Default::default() }], ..item.clone() },
            Some("Ders"),
            &[Highlight { quote: "Merhaba".into(), note: Some("vurgulandı".into()), ..Default::default() }],
        );
        assert!(md.starts_with("---\nid: \"x:1\"\n"));
        assert!(md.contains("  - \"iki-kelime\"\n"));
        assert!(md.contains("![](media/ab12.jpg)"));
        assert!(md.contains("## Vurgular") && md.contains("> Merhaba") && md.contains("- Not: vurgulandı"));
        assert!(md.contains("## Yanıtlar") && md.contains("**@b**: haklısın"));
        assert_eq!(files, vec!["ab12.jpg"]);
        let row = csv_row(&item, None);
        assert!(row.contains("\"Merhaba \"\"dünya\"\"\nikinci satır\""));
        let mut names = Names::default();
        let a = names.next(&item);
        let b = names.next(&item);
        assert_eq!(a, "2023-11-14 Merhaba dünya.md");
        assert_eq!(b, "2023-11-14 Merhaba dünya 2.md");
        assert_eq!(safe_name("a/b:c"), "a b c");
    }
}
