//! Export formats: Markdown (one note per item, Obsidian-friendly YAML front
//! matter, media next to it) and CSV (one row per item).

use std::collections::HashSet;

use chrono::DateTime;

use crate::model::Item;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Format {
    Markdown,
    Csv,
    Json,
}

impl Format {
    pub fn parse(s: &str) -> Option<Self> {
        match s.trim().to_ascii_lowercase().as_str() {
            "md" | "markdown" | "obsidian" => Some(Self::Markdown),
            "csv" => Some(Self::Csv),
            "json" | "jsonl" => Some(Self::Json),
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
pub fn markdown(item: &Item, folder: Option<&str>) -> (String, Vec<String>) {
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
        let (md, files) = markdown(&item, Some("Ders"));
        assert!(md.starts_with("---\nid: \"x:1\"\n"));
        assert!(md.contains("  - \"iki-kelime\"\n"));
        assert!(md.contains("![](media/ab12.jpg)"));
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
