//! v0.2 / v0.3 commands: rules, archive and file imports, export, meaning
//! search, related items, summaries, duplicates.

use std::collections::{HashMap, HashSet};
use std::io::Write as _;

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use super::*;
use crate::ai::{Space, embed_text, fuse_weighted};
use crate::archive;
use crate::db::SearchResult;
use crate::db::{DuplicateGroup, Rule};
use crate::export::{self, Format, Names};
use crate::localfile;
use crate::model::Platform;

#[derive(Debug, Default, Serialize)]
pub struct ArchiveReport {
    pub found: usize,
    pub new: usize,
    pub existing: usize,
    pub sources: Vec<ArchiveSource>,
}

#[derive(Debug, Serialize)]
pub struct ArchiveSource {
    pub file: String,
    pub count: usize,
}

#[derive(Debug, Default, Serialize)]
pub struct FilesReport {
    pub files: usize,
    /// New items made from the files.
    pub new: usize,
    /// Files that became the video of a post already in the library.
    pub attached: usize,
    /// Files already in the library (same content).
    pub existing: usize,
    pub failed: usize,
    pub ids: Vec<String>,
}

#[derive(Debug, Default, Serialize)]
pub struct ExportReport {
    pub count: usize,
    pub path: String,
    pub media: usize,
}

#[derive(Debug, Default, Serialize)]
pub struct EmbedReport {
    pub done: usize,
    pub remaining: i64,
    pub total: i64,
}

#[derive(Debug, Serialize)]
pub struct RuleRow {
    #[serde(flatten)]
    pub rule: Rule,
    /// Items in the library the rule's search finds now.
    pub matches: i64,
}

#[derive(Debug, Serialize)]
pub struct BatchSuggestion {
    pub id: String,
    pub item: Item,
    pub tags: Vec<String>,
    pub folder_id: Option<i64>,
    pub folder_name: Option<String>,
}

/// Centered cosine a meaning hit needs to be shown.
const SEMANTIC_MIN: f32 = 0.42;
/// Similar items below this are not shown as related.
const RELATED_MIN: f32 = 0.45;
/// Two items this alike are offered as duplicates.
const DUPLICATE_MIN: f32 = 0.93;

impl Library {
    // --- Rules ---------------------------------------------------------------

    pub fn rule_rows(&self) -> Result<Vec<RuleRow>> {
        let store = self.lock_store()?;
        let rules = store.rules()?;
        let mut out = Vec::with_capacity(rules.len());
        for rule in rules {
            let matches = store.count_matching(&Query::parse(&rule.query))?;
            out.push(RuleRow { rule, matches });
        }
        Ok(out)
    }

    fn check_rule(query: &str) -> Result<()> {
        if Query::parse(query) == Query::default() { Err(CoreError::EmptyRule) } else { Ok(()) }
    }

    // --- Archives (bookmarks.html, platform data downloads, CSV) ---------------

    pub fn import_archive(self: &Arc<Self>, path: &Path, tags: &[String], folder: Option<i64>, keep_folders: bool) -> Result<ArchiveReport> {
        let found = archive::scan(path).map_err(|source| CoreError::IoPath { path: path.display().to_string(), source })?;
        if found.stubs.is_empty() {
            return Err(CoreError::NothingToImport);
        }
        let mut report = ArchiveReport {
            found: found.stubs.len(),
            sources: found.sources.iter().map(|(file, count)| ArchiveSource { file: file.clone(), count: *count }).collect(),
            ..Default::default()
        };
        // One item per post even if it is both liked and saved.
        let mut order: Vec<String> = vec![];
        let mut by_id: HashMap<String, (Item, Option<String>)> = HashMap::new();
        for stub in &found.stubs {
            let item = archive::to_item(stub);
            match by_id.get_mut(&item.id) {
                Some((have, _)) => {
                    for t in &item.tags {
                        if !have.tags.contains(t) {
                            have.tags.push(t.clone());
                        }
                    }
                }
                None => {
                    order.push(item.id.clone());
                    by_id.insert(item.id.clone(), (item, stub.folder.clone()));
                }
            }
        }
        let existing = self.lock_store()?.existing_ids(&order)?;
        let mut new_items = vec![];
        for id in &order {
            let Some((item, src_folder)) = by_id.remove(id) else { continue };
            if existing.contains(id) {
                // Known already: keep what is there, only add the labels.
                let mut add: Vec<String> = item.tags.clone();
                add.extend(tags.iter().cloned());
                if !add.is_empty() {
                    self.lock_store()?.edit_tags(std::slice::from_ref(id), &add, &[])?;
                }
                report.existing += 1;
                continue;
            }
            let mut item = item;
            if folder.is_none()
                && keep_folders
                && let Some(f) = src_folder
            {
                item.folder_id = Some(self.lock_store()?.ensure_folder(&format!("Yer imleri/{f}"))?);
            }
            new_items.push(item);
        }
        for chunk in new_items.chunks_mut(400) {
            let saved = self.save_into(chunk, tags, folder)?;
            report.new += saved.new;
            self.lock_store()?.mark_stubs(&saved.ids)?;
        }
        self.kick_media();
        Ok(report)
    }

    /// Fills in up to `limit` stubs from the network, one at a time and
    /// unhurried. Returns how many were tried.
    pub fn fill_stubs(&self, limit: i64) -> Result<usize> {
        let todo = self.lock_store()?.stubs_to_fill(limit)?;
        for (i, stub) in todo.iter().enumerate() {
            if i > 0 {
                for _ in 0..8 {
                    if self.stopping.load(Ordering::Acquire) {
                        return Ok(i);
                    }
                    std::thread::sleep(Duration::from_millis(200));
                }
            }
            if self.stopping.load(Ordering::Acquire) {
                return Ok(i);
            }
            // A page that answers is done even if it says little; Instagram
            // answers everyone with its login page, which is not the post.
            let got = self.fetcher.capture(&stub.url).ok().filter(|c| {
                !matches!(stub.platform, Platform::Instagram | Platform::Threads)
                    || !c.text.trim().is_empty()
                    || !c.media.is_empty()
                    || c.author_handle.is_some()
            });
            let mut store = self.lock_store()?;
            let Some(mut item) = got else {
                store.stub_failed(&stub.id)?;
                continue;
            };
            item.id = stub.id.clone();
            item.platform = stub.platform;
            item.saved_at = stub.saved_at;
            item.tags = vec![];
            item.author_handle = item.author_handle.or_else(|| stub.author_handle.clone());
            item.title = item.title.or_else(|| stub.title.clone());
            if item.text.trim().is_empty() {
                item.text = stub.text.clone();
            }
            // A video file that came from disk stays with the post.
            for old in stub.media.iter().filter(|m| m.video_file.is_some()) {
                match item.media.iter_mut().find(|m| m.kind != MediaKind::Image && m.video_file.is_none()) {
                    Some(m) => m.video_file = old.video_file.clone(),
                    None => item.media.push(old.clone()),
                }
            }
            if item.media.is_empty() {
                item.media = stub.media.clone();
            }
            store.upsert_all(std::slice::from_mut(&mut item))?;
            store.stub_filled(&stub.id)?;
            store.apply_rules(std::slice::from_ref(&stub.id))?;
        }
        Ok(todo.len())
    }

    // --- Files from disk -----------------------------------------------------

    pub fn import_files(self: &Arc<Self>, paths: &[PathBuf], tags: &[String], folder: Option<i64>) -> Result<FilesReport> {
        let files = localfile::collect(paths);
        if files.is_empty() {
            return Err(CoreError::NothingToImport);
        }
        let mut report = FilesReport { files: files.len(), ..Default::default() };
        for path in &files {
            if self.stopping.load(Ordering::Acquire) {
                break;
            }
            match self.import_file(path, tags, folder) {
                Ok((kind, id)) => {
                    match kind {
                        FileOutcome::New => report.new += 1,
                        FileOutcome::Attached => report.attached += 1,
                        FileOutcome::Existing => report.existing += 1,
                    }
                    report.ids.push(id);
                }
                Err(e) => {
                    report.failed += 1;
                    append_log(&self.root, &format!("dosya {}: {e}", path.display()));
                }
            }
        }
        self.kick_media();
        Ok(report)
    }

    /// A video or picture the user has (saved from the app, a screen
    /// recording) put on an existing post: the video goes in its empty
    /// video slot, a picture after its pictures. True if it changed.
    pub fn attach_file(&self, id: &str, path: &Path) -> Result<bool> {
        let kind = localfile::kind_of(path).ok_or(CoreError::NothingToImport)?;
        if self.lock_store()?.existing_ids(&[id.to_string()])?.is_empty() {
            return Err(CoreError::ItemNotFound);
        }
        let f = std::fs::File::open(path).map_err(|source| CoreError::IoPath { path: path.display().to_string(), source })?;
        let name = self.media.put_reader(f, localfile::content_type(path))?;
        let mut store = self.lock_store()?;
        Ok(if kind == MediaKind::Image { store.attach_image(id, &name)? } else { store.attach_video(id, &name)? })
    }

    fn import_file(&self, path: &Path, tags: &[String], folder: Option<i64>) -> Result<(FileOutcome, String)> {
        let kind = localfile::kind_of(path).ok_or(CoreError::NothingToImport)?;
        let f = std::fs::File::open(path).map_err(|source| CoreError::IoPath { path: path.display().to_string(), source })?;
        let name = self.media.put_reader(f, localfile::content_type(path))?;
        let file_name = path.file_name().and_then(|n| n.to_str()).unwrap_or("");
        let is_video = kind != MediaKind::Image;

        // A post id in the name: this is a download of that post.
        let post = if is_video {
            localfile::tiktok_id(file_name)
                .map(|id| (Platform::Tiktok, format!("tiktok:{id}"), format!("https://www.tiktok.com/@/video/{id}")))
                .or_else(|| {
                    localfile::youtube_id(file_name)
                        .map(|id| (Platform::Youtube, format!("youtube:{id}"), format!("https://www.youtube.com/watch?v={id}")))
                })
        } else {
            None
        };
        if let Some((platform, id, url)) = post {
            let exists = !self.lock_store()?.existing_ids(std::slice::from_ref(&id))?.is_empty();
            if exists {
                let attached = self.lock_store()?.attach_video(&id, &name)?;
                if !tags.is_empty() {
                    self.lock_store()?.edit_tags(std::slice::from_ref(&id), tags, &[])?;
                }
                return Ok((if attached { FileOutcome::Attached } else { FileOutcome::Existing }, id));
            }
            let mut m = Media::image(url.clone());
            m.kind = MediaKind::Video;
            m.video_file = Some(name);
            let mut items = [Item { id: id.clone(), platform, url, media: vec![m], stub: true, ..Default::default() }];
            self.save_into(&mut items, tags, folder)?;
            self.lock_store()?.mark_stubs(std::slice::from_ref(&id))?;
            return Ok((FileOutcome::New, id));
        }

        let stem = name.split('.').next().unwrap_or(&name);
        let id = format!("local:{}", stem.get(..16).unwrap_or(stem));
        if !self.lock_store()?.existing_ids(std::slice::from_ref(&id))?.is_empty() {
            if !tags.is_empty() {
                self.lock_store()?.edit_tags(std::slice::from_ref(&id), tags, &[])?;
            }
            return Ok((FileOutcome::Existing, id));
        }
        let url = localfile::file_url(path);
        let mut m = Media::image(url.clone());
        m.kind = kind;
        if is_video {
            m.video_file = Some(name);
        } else {
            m.file = Some(name);
        }
        let title = path.file_stem().and_then(|s| s.to_str()).map(str::to_string);
        let mut items = [Item {
            id: id.clone(),
            platform: Platform::Local,
            url,
            title,
            created_at: localfile::file_time(path),
            media: vec![m],
            ..Default::default()
        }];
        self.save_into(&mut items, tags, folder)?;
        Ok((FileOutcome::New, id))
    }

    /// Stores a poster the app drew for a video that came without one.
    pub fn set_poster(&self, id: &str, video_file: &str, poster: &Path) -> Result<()> {
        let bytes = std::fs::read(poster).map_err(|source| CoreError::IoPath { path: poster.display().to_string(), source })?;
        let name = self.media.put(&bytes, "jpg")?;
        self.lock_store()?.set_poster(id, video_file, &name)?;
        Ok(())
    }

    // --- Export ----------------------------------------------------------------

    /// One HTML page of what `q` finds, pictures inside it up to 80 MB
    /// (the rest left out), written in `dest` as `<title>.html`.
    pub fn export_html(&self, q: &str, dest: &Path, title: Option<&str>, english: bool) -> Result<ExportReport> {
        use base64::Engine;
        const BUDGET: usize = 80 << 20;
        let io = |source: std::io::Error| CoreError::IoPath { path: dest.display().to_string(), source };
        std::fs::create_dir_all(dest).map_err(io)?;
        let query = Query::parse(q);
        let folders: HashMap<i64, String> = self.lock_store()?.folders()?.into_iter().map(|f| (f.id, f.name)).collect();
        let mut items = vec![];
        let mut offset = 0;
        loop {
            let page = self.lock_store()?.search(&query, Sort::SavedNewest, 200, offset)?;
            if page.items.is_empty() {
                break;
            }
            offset += page.items.len() as i64;
            items.extend(page.items);
        }
        let title = title.map(str::trim).filter(|t| !t.is_empty()).map(str::to_string).unwrap_or_else(|| "wroopmark".into());
        let mut used = 0usize;
        let mut media = 0usize;
        let mut embed = |name: &str| -> Option<String> {
            let kind = export::image_type(name)?;
            let path = self.media.path(name);
            let len = usize::try_from(std::fs::metadata(&path).ok()?.len()).ok()?;
            if used + len > BUDGET {
                return None;
            }
            let bytes = std::fs::read(&path).ok()?;
            used += len;
            media += 1;
            Some(format!("data:{kind};base64,{}", base64::engine::general_purpose::STANDARD.encode(bytes)))
        };
        let folder_of = |i: &Item| i.folder_id.and_then(|f| folders.get(&f).cloned());
        let hl_of = |i: &Item| self.lock_store().ok().and_then(|s| s.highlights(&i.id).ok()).unwrap_or_default();
        let html = export::html_page(&title, &items, &folder_of, &hl_of, english, &mut embed);
        let path = dest.join(format!("{}.html", export::safe_name(&title)));
        std::fs::write(&path, html).map_err(io)?;
        Ok(ExportReport { path: path.display().to_string(), count: items.len(), media })
    }

    pub fn export(&self, q: &str, format: Format, dest: &Path, with_media: bool) -> Result<ExportReport> {
        if format == Format::Html {
            return self.export_html(q, dest, None, false);
        }
        let io = |source: std::io::Error| CoreError::IoPath { path: dest.display().to_string(), source };
        std::fs::create_dir_all(dest).map_err(io)?;
        let query = Query::parse(q);
        let folders: HashMap<i64, String> = self.lock_store()?.folders()?.into_iter().map(|f| (f.id, f.name)).collect();
        let stamp = chrono::Utc::now().format("%Y-%m-%d").to_string();
        let mut report = ExportReport::default();
        let mut names = Names::default();
        let mut copied: HashSet<String> = HashSet::new();
        let mut out_file = match format {
            Format::Markdown | Format::Html => {
                report.path = dest.display().to_string();
                None
            }
            Format::Csv | Format::Json => {
                let ext = if format == Format::Csv { "csv" } else { "jsonl" };
                let p = dest.join(format!("wroopmark-{stamp}.{ext}"));
                report.path = p.display().to_string();
                let mut f = std::io::BufWriter::new(std::fs::File::create(&p).map_err(io)?);
                if format == Format::Csv {
                    f.write_all(export::CSV_HEADER.as_bytes()).map_err(io)?;
                }
                Some(f)
            }
        };
        let mut offset = 0;
        loop {
            let page = self.lock_store()?.search(&query, Sort::SavedNewest, 200, offset)?;
            if page.items.is_empty() {
                break;
            }
            offset += page.items.len() as i64;
            for item in &page.items {
                let folder = item.folder_id.and_then(|f| folders.get(&f)).map(String::as_str);
                match (&mut out_file, format) {
                    (Some(f), Format::Csv) => f.write_all(export::csv_row(item, folder).as_bytes()).map_err(io)?,
                    (Some(f), _) => {
                        serde_json::to_writer(&mut *f, item)?;
                        f.write_all(b"\n").map_err(io)?;
                    }
                    (None, _) => {
                        let hl = self.lock_store()?.highlights(&item.id)?;
                        let (md, files) = export::markdown(item, folder, &hl);
                        std::fs::write(dest.join(names.next(item)), md).map_err(io)?;
                        if with_media {
                            for name in files {
                                if !copied.insert(name.clone()) {
                                    continue;
                                }
                                let src = self.media.path(&name);
                                let dst = dest.join("media").join(&name);
                                if src.is_file() && !dst.exists() {
                                    std::fs::create_dir_all(dest.join("media")).map_err(io)?;
                                    // APFS clones the file: no extra space.
                                    std::fs::copy(&src, &dst).map_err(io)?;
                                    report.media += 1;
                                }
                            }
                        }
                    }
                }
                report.count += 1;
            }
        }
        if let Some(mut f) = out_file {
            f.flush().map_err(io)?;
        }
        Ok(report)
    }

    // --- Meaning search --------------------------------------------------------

    /// Embeds up to `limit` items that have no current vector.
    pub fn embed_pending(&self, limit: i64) -> Result<EmbedReport> {
        let rows = self.lock_store()?.embed_pending(limit)?;
        let mut report = EmbedReport::default();
        if !rows.is_empty() {
            let texts: Vec<String> = rows.iter().map(|(_, item)| embed_text(item)).collect();
            let (model, vecs) = self.ai.embed(&texts)?;
            let mut store = self.lock_store()?;
            if !model.is_empty() {
                let known = store.setting("vector_model")?;
                if known.as_deref() != Some(model.as_str()) {
                    // Another model: old vectors are not comparable.
                    if known.is_some() {
                        store.clear_vectors()?;
                    }
                    store.set_setting("vector_model", &model)?;
                }
            }
            // An item the model gave nothing for still gets a (empty) row,
            // so it is not tried again until it changes.
            let packed: Vec<(i64, Vec<u8>)> = rows
                .iter()
                .map(|(pk, _)| *pk)
                .zip(vecs.into_iter().chain(std::iter::repeat(None)))
                .map(|(pk, v)| (pk, v.unwrap_or_default()))
                .collect();
            store.set_vectors(&packed)?;
            report.done = packed.len();
        }
        let (done, total) = self.lock_store()?.vector_progress()?;
        report.total = total;
        report.remaining = (total - done).max(0);
        Ok(report)
    }

    /// The words of a search, without its filters: what gets embedded.
    fn query_words(q: &str) -> String {
        crate::query::split(q)
            .into_iter()
            .filter(|t| !t.starts_with('-') && !t.starts_with('@') && !(t.contains(':') && !t.starts_with('"')))
            .map(|t| t.trim_matches('"').to_string())
            .collect::<Vec<_>>()
            .join(" ")
    }

    /// Related words for a search from the on-device model (cached; empty
    /// when the model is not available).
    fn expansion(&self, words: &str) -> Vec<String> {
        let key = crate::text::fold(words);
        if let Some(hit) = self.expansions.lock().ok().and_then(|m| m.get(&key).cloned()) {
            return hit;
        }
        let terms = self.ai.expand(words).unwrap_or_default();
        if let Ok(mut m) = self.expansions.lock() {
            if m.len() > 200 {
                m.clear();
            }
            m.insert(key, terms.clone());
        }
        terms
    }

    /// Meaning search: the words as typed, the same search widened with
    /// related words (synonyms, the other language) by the on-device
    /// model, and the nearest vectors, fused in that order of trust.
    /// Filters (tags, dates…) apply to all three. Without words it is the
    /// normal search.
    pub fn semantic_search(&self, q: &str, sort: Sort, limit: i64, offset: i64) -> Result<SearchResult> {
        let query = Query::parse(q);
        let words = Self::query_words(q);
        if !query.has_text() || words.trim().is_empty() {
            return Ok(self.lock_store()?.search(&query, sort, limit, offset)?);
        }
        let terms = self.expansion(&words);
        let qvec = self.ai.embed(std::slice::from_ref(&words)).ok().and_then(|(_, v)| v.into_iter().next().flatten());
        let store = self.lock_store()?;
        let exact = store.fts_pks(&query, 300)?;
        let mut all_terms = terms.clone();
        all_terms.extend(words.split_whitespace().map(str::to_string));
        let wide = store.fts_any_pks(&all_terms, &query, 300)?;
        let mut near: Vec<i64> = vec![];
        if let Some(qv) = qvec {
            let space = Space::new(&store.vectors_for(&Query::default())?);
            // Filters narrow the candidates; the space stays the whole library.
            let allowed: Option<HashSet<i64>> =
                query.filters_items().then(|| store.vectors_for(&query)).transpose()?.map(|rows| rows.into_iter().map(|(pk, _)| pk).collect());
            near = space
                .nearest(&qv, 400, None)
                .into_iter()
                .filter(|(pk, s)| *s >= SEMANTIC_MIN && allowed.as_ref().is_none_or(|a| a.contains(pk)))
                .take(100)
                .map(|(pk, _)| pk)
                .collect();
        }
        if std::env::var_os("WROOPMARK_DEBUG").is_some() {
            eprintln!("terms {terms:?} exact {} wide {} near {}", exact.len(), wide.len(), near.len());
        }
        let fused = fuse_weighted(&[(&exact, 1.0), (&wide, 0.8), (&near, 0.5)]);
        let total = fused.len() as i64;
        let start = usize::try_from(offset.max(0)).unwrap_or(0).min(fused.len());
        let end = start.saturating_add(usize::try_from(limit.max(0)).unwrap_or(0)).min(fused.len());
        let items = store.items_by_pks(fused.get(start..end).unwrap_or(&[]))?;
        let links = if offset == 0 { store.search(&query, Sort::Default, 1, 0)?.links } else { vec![] };
        Ok(SearchResult { items, total, links })
    }

    /// Items closest in meaning (or visual appearance via image fingerprint) to this one.
    pub fn related(&self, id: &str, limit: i64) -> Result<Vec<Item>> {
        let store = self.lock_store()?;
        let k = usize::try_from(limit.clamp(1, 50)).unwrap_or(8);
        let mut pks: Vec<i64> = vec![];
        if let Some((pk, v)) = store.vector_of(id)?
            && !v.is_empty()
        {
            let space = Space::new(&store.vectors_for(&Query::default())?);
            pks = space.nearest(&v, k, Some(pk)).into_iter().filter(|(_, s)| *s >= RELATED_MIN).map(|(pk, _)| pk).collect();
        }
        if pks.len() < k
            && let Some(target_hash) = store.imghash_of(id)?
        {
            let target_bits = target_hash as u64;
            let mut visual: Vec<(u32, i64)> = store
                .imghashes()?
                .into_iter()
                .filter(|(_, oid, oh)| oid != id && (8..=56).contains(&(*oh as u64).count_ones()))
                .filter_map(|(opk, _, oh)| {
                    let dist = (target_bits ^ (oh as u64)).count_ones();
                    (dist <= 10).then_some((dist, opk))
                })
                .collect();
            visual.sort_by_key(|(d, _)| *d);
            for (_, opk) in visual {
                if !pks.contains(&opk) {
                    pks.push(opk);
                    if pks.len() >= k {
                        break;
                    }
                }
            }
        }
        if pks.is_empty() {
            return Ok(vec![]);
        }
        Ok(store.items_by_pks(&pks)?)
    }

    /// A short summary and tag ideas from the on-device model, stored on the item.
    pub fn summarize(&self, id: &str) -> Result<Item> {
        let (item, known) = {
            let store = self.lock_store()?;
            let item = store.get(id)?.ok_or(CoreError::ItemNotFound)?;
            let mut tags = store.tags()?;
            tags.sort_by_key(|a| std::cmp::Reverse(a.count));
            (item, tags.into_iter().take(80).map(|t| t.name).collect::<Vec<_>>())
        };
        let mut text = String::new();
        if let Some(a) = item.author_handle.as_deref().or(item.author_name.as_deref()) {
            text.push_str(&format!("Yazar: {a}\n"));
        }
        text.push_str(&format!("Kaynak: {}\n", item.url));
        text.push_str(&embed_text(&item));
        if let Some(e) = item.extra.as_deref() {
            text.push('\n');
            text.extend(e.chars().take(2000));
        }
        let text: String = text.chars().take(3500).collect();
        let (summary, tags) = self.ai.summarize(&text, &known)?;
        let have: HashSet<String> = item.tags.iter().map(|t| t.to_lowercase()).collect();
        let mut ideas: Vec<String> = vec![];
        for t in tags {
            let t = t.trim().trim_start_matches('#').to_lowercase();
            if !t.is_empty() && t.chars().count() <= 40 && !have.contains(&t) && !ideas.contains(&t) {
                ideas.push(t);
            }
        }
        ideas.truncate(5);
        let mut store = self.lock_store()?;
        store.set_ai(id, (!summary.is_empty()).then_some(summary.as_str()), &ideas)?;
        store.get(id)?.ok_or(CoreError::ItemNotFound)
    }

    pub fn ai_status(&self) -> Result<Value> {
        let mut status = self.ai.status();
        let store = self.lock_store()?;
        let (done, total) = store.vector_progress()?;
        let stubs = store.stub_info()?;
        let helper =
            crate::ai::Helper::path().map(|p| p.display().to_string()).or_else(|| crate::ai::has_callback().then(|| "in-process".to_string()));
        if let Some(obj) = status.as_object_mut() {
            obj.insert("vectors".into(), json!({"done": done, "total": total}));
            obj.insert("stubs".into(), serde_json::to_value(stubs)?);
            let (copies, pending) = store.snapshot_count()?;
            obj.insert("snapshots".into(), json!({"done": copies, "pending": pending}));
            obj.insert("helper".into(), json!(helper));
        }
        Ok(status)
    }

    // --- Duplicates --------------------------------------------------------------

    pub fn duplicates(&self) -> Result<Vec<DuplicateGroup>> {
        let store = self.lock_store()?;
        let mut groups: Vec<(&str, Vec<i64>)> = store.duplicate_candidates()?;
        // A blank or one-colour picture has an almost empty (or full)
        // fingerprint and would pair with every other such picture.
        let hashes: Vec<_> = store.imghashes()?.into_iter().filter(|(_, _, h)| (8..=56).contains(&(*h as u64).count_ones())).collect();
        if hashes.len() <= 20_000 {
            for (i, (pk1, _, h1)) in hashes.iter().enumerate() {
                for (pk2, _, h2) in hashes.iter().skip(i + 1) {
                    if ((*h1 as u64) ^ (*h2 as u64)).count_ones() <= 4 {
                        groups.push(("media", vec![*pk1, *pk2]));
                    }
                }
            }
        }
        let space = Space::new(&store.vectors_for(&Query::default())?);
        if space.len() <= 20_000 {
            groups.extend(space.pairs(DUPLICATE_MIN).into_iter().map(|(a, b)| ("similar", vec![a, b])));
        }
        // Union of overlapping groups; the strongest reason names it.
        let rank = |r: &str| match r {
            "media" => 0,
            "text" => 1,
            _ => 2,
        };
        let mut parent: HashMap<i64, i64> = HashMap::new();
        fn root(parent: &mut HashMap<i64, i64>, x: i64) -> i64 {
            let mut r = x;
            while let Some(&p) = parent.get(&r) {
                if p == r {
                    break;
                }
                r = p;
            }
            parent.insert(x, r);
            r
        }
        let mut reason: HashMap<i64, &str> = HashMap::new();
        for (why, pks) in &groups {
            let Some(&first) = pks.first() else { continue };
            parent.entry(first).or_insert(first);
            for &pk in pks {
                parent.entry(pk).or_insert(pk);
                let (a, b) = (root(&mut parent, first), root(&mut parent, pk));
                if a != b {
                    parent.insert(b, a);
                }
            }
            let r = root(&mut parent, first);
            let best = reason.get(&r).copied().filter(|have| rank(have) <= rank(why)).unwrap_or(why);
            reason.insert(r, best);
        }
        let mut members: HashMap<i64, Vec<i64>> = HashMap::new();
        let keys: Vec<i64> = parent.keys().copied().collect();
        for pk in keys {
            let r = root(&mut parent, pk);
            members.entry(r).or_default().push(pk);
        }
        // Reasons were recorded on roots that may have been merged since.
        let mut group_reason: HashMap<i64, &str> = HashMap::new();
        for (r, why) in &reason {
            let top = root(&mut parent, *r);
            let best = group_reason.get(&top).copied().filter(|have| rank(have) <= rank(why)).unwrap_or(why);
            group_reason.insert(top, best);
        }
        let ignored: HashSet<String> =
            store.setting("dup_ignored")?.and_then(|s| serde_json::from_str::<Vec<String>>(&s).ok()).unwrap_or_default().into_iter().collect();
        let mut out = vec![];
        let mut list: Vec<(i64, Vec<i64>)> = members.into_iter().filter(|(_, m)| (2..=20).contains(&m.len())).collect();
        list.sort_by_key(|(_, m)| std::cmp::Reverse(m.iter().copied().max().unwrap_or(0)));
        for (r, mut pks) in list {
            pks.sort_unstable();
            let mut ids = store.pk_ids(&pks)?;
            ids.sort();
            if ignored.contains(&ids.join(",")) {
                continue;
            }
            let items = store.items_by_pks(&pks)?;
            out.push(DuplicateGroup { reason: group_reason.get(&r).copied().unwrap_or("similar").to_string(), items });
            if out.len() >= 200 {
                break;
            }
        }
        Ok(out)
    }

    pub fn ignore_duplicates(&self, ids: &[String]) -> Result<()> {
        let mut store = self.lock_store()?;
        let mut list: Vec<String> = store.setting("dup_ignored")?.and_then(|s| serde_json::from_str(&s).ok()).unwrap_or_default();
        let mut ids = ids.to_vec();
        ids.sort();
        list.push(ids.join(","));
        store.set_setting("dup_ignored", &serde_json::to_string(&list)?)?;
        Ok(())
    }

    pub fn suggest_batch(&self, q: &str, limit: i64) -> Result<Vec<BatchSuggestion>> {
        let lim = limit.clamp(1, 25);
        let q = if q.trim().is_empty() { "is:untagged" } else { q };
        let found = self.lock_store()?.search(&Query::parse(q), Sort::SavedNewest, lim, 0)?;
        let llm_ready = self.ai.status().get("llm_ready").and_then(Value::as_bool) == Some(true);
        let mut out = vec![];
        for mut item in found.items {
            if item.ai_tags.is_empty()
                && llm_ready
                && let Ok(updated) = self.summarize(&item.id)
            {
                item = updated;
            }
            let have: HashSet<String> = item.tags.iter().map(|t| t.to_lowercase()).collect();
            let tags: Vec<String> = item.ai_tags.iter().filter(|t| !have.contains(&t.to_lowercase())).cloned().collect();
            let folders = self.lock_store()?.suggest_folders(&item.id, 1)?;
            let best_folder = folders.into_iter().next().filter(|_| item.folder_id.is_none());
            if tags.is_empty() && best_folder.is_none() {
                continue;
            }
            out.push(BatchSuggestion {
                id: item.id.clone(),
                folder_id: best_folder.as_ref().map(|f| f.id),
                folder_name: best_folder.map(|f| f.name),
                item,
                tags,
            });
        }
        Ok(out)
    }
}

enum FileOutcome {
    New,
    Attached,
    Existing,
}

fn default_true() -> bool {
    true
}

pub(super) fn dispatch<S: Sink>(lib: &Arc<Library>, cmd: &str, req: Req<'_>) -> Result<S::Out> {
    match cmd {
        "rules" => S::ok(lib.rule_rows()?),
        "add_rule" => {
            #[derive(Deserialize)]
            struct AddRule {
                query: String,
                tag: Option<String>,
                folder_id: Option<i64>,
                #[serde(default)]
                apply: bool,
            }
            let a: AddRule = req.parse()?;
            Library::check_rule(&a.query)?;
            let mut store = lib.lock_store()?;
            let rule = store.add_rule(&a.query, a.tag.as_deref(), a.folder_id)?;
            let applied = if a.apply { store.apply_rule(&rule, None)? } else { 0 };
            S::ok(json!({"rule": rule, "applied": applied}))
        }
        "update_rule" => {
            #[derive(Deserialize)]
            struct UpdateRule {
                id: i64,
                query: String,
                tag: Option<String>,
                folder_id: Option<i64>,
                #[serde(default = "default_true")]
                enabled: bool,
            }
            let a: UpdateRule = req.parse()?;
            Library::check_rule(&a.query)?;
            lib.lock_store()?.update_rule(a.id, &a.query, a.tag.as_deref(), a.folder_id, a.enabled)?;
            S::ok(true)
        }
        "delete_rule" => {
            lib.lock_store()?.delete_rule(req.parse::<FolderId>()?.id)?;
            S::ok(true)
        }
        "apply_rule" => {
            let id = req.parse::<FolderId>()?.id;
            let mut store = lib.lock_store()?;
            let rule = store.rule(id)?.ok_or(CoreError::ItemNotFound)?;
            S::ok(store.apply_rule(&rule, None)?)
        }
        "count" => {
            let p: Page = req.parse()?;
            S::ok(lib.lock_store()?.count_matching(&Query::parse(&p.q))?)
        }
        "import_archive" => {
            #[derive(Deserialize)]
            struct ImportArchive {
                path: String,
                #[serde(default)]
                tags: Vec<String>,
                folder_id: Option<i64>,
                #[serde(default = "default_true")]
                keep_folders: bool,
            }
            let a: ImportArchive = req.parse()?;
            S::ok(lib.import_archive(Path::new(&a.path), &a.tags, a.folder_id, a.keep_folders)?)
        }
        "import_files" => {
            #[derive(Deserialize)]
            struct ImportFiles {
                paths: Vec<String>,
                #[serde(default)]
                tags: Vec<String>,
                folder_id: Option<i64>,
            }
            let a: ImportFiles = req.parse()?;
            let paths: Vec<PathBuf> = a.paths.iter().map(PathBuf::from).collect();
            S::ok(lib.import_files(&paths, &a.tags, a.folder_id)?)
        }
        "attach_file" => {
            #[derive(Deserialize)]
            struct AttachFile {
                id: String,
                path: String,
            }
            let a: AttachFile = req.parse()?;
            S::ok(lib.attach_file(&a.id, Path::new(&a.path))?)
        }
        "needs_video" => S::ok(lib.lock_store()?.needs_video(req.parse::<Limit>()?.limit.clamp(1, 200))?),
        "fill_stubs" => S::ok(lib.fill_stubs(req.parse::<Limit>()?.limit.clamp(1, 50))?),
        "pause" => {
            lib.pause();
            S::ok(true)
        }
        "set_media_paused" => {
            #[derive(Deserialize)]
            struct On {
                on: bool,
            }
            let on = req.parse::<On>()?.on;
            lib.lock_store()?.set_setting("media_paused", if on { "1" } else { "0" })?;
            if !on {
                lib.kick_media();
            }
            S::ok(true)
        }
        // The share sheet (a short-lived extension): store the link at once,
        // with no network; the app fills in text and media later.
        "save_link" => {
            #[derive(Deserialize)]
            struct SaveLink {
                url: String,
                #[serde(default)]
                tags: Vec<String>,
                note: Option<String>,
                title: Option<String>,
                folder_id: Option<i64>,
            }
            let a: SaveLink = req.parse()?;
            let url = a.url.trim();
            if !(url.starts_with("http://") || url.starts_with("https://")) {
                return Err(CoreError::InvalidUrl);
            }
            let mut item =
                archive::to_item(&archive::Stub { url: url.to_string(), title: a.title.filter(|t| !t.trim().is_empty()), ..Default::default() });
            item.saved_at = 0;
            item.note = a.note.filter(|n| !n.trim().is_empty());
            let id = item.id.clone();
            let existed = !lib.lock_store()?.existing_ids(std::slice::from_ref(&id))?.is_empty();
            if existed {
                if !a.tags.is_empty() {
                    lib.lock_store()?.edit_tags(std::slice::from_ref(&id), &a.tags, &[])?;
                }
                if let Some(n) = item.note.as_deref() {
                    lib.lock_store()?.set_note(&id, Some(n))?;
                }
                if a.folder_id.is_some() {
                    lib.lock_store()?.move_to_folder(&id, a.folder_id)?;
                }
            } else {
                lib.save_into(std::slice::from_mut(&mut item), &a.tags, a.folder_id)?;
                lib.lock_store()?.mark_stubs(std::slice::from_ref(&id))?;
            }
            S::ok(json!({"id": id, "new": !existed}))
        }
        "add_note" => {
            #[derive(Deserialize)]
            struct AddNote {
                text: String,
                title: Option<String>,
                #[serde(default)]
                tags: Vec<String>,
                folder_id: Option<i64>,
            }
            let a: AddNote = req.parse()?;
            let text = a.text.trim().to_string();
            let title = a.title.map(|t| t.trim().to_string()).filter(|t| !t.is_empty());
            if text.is_empty() && title.is_none() {
                return Err(CoreError::InvalidUrl);
            }
            let now = chrono::Utc::now().timestamp();
            let seed = format!("{}:{}:{now}", title.as_deref().unwrap_or(""), text);
            let hash: String = crate::text::hash_hex(seed.as_bytes()).chars().take(16).collect();
            let id = format!("local:{hash}");
            let mut item = Item {
                id: id.clone(),
                platform: Platform::Local,
                url: format!("https://wroopmark.local/note/{hash}"),
                title,
                text,
                created_at: Some(now),
                saved_at: now,
                ..Default::default()
            };
            lib.save_into(std::slice::from_mut(&mut item), &a.tags, a.folder_id)?;
            S::ok(lib.lock_store()?.get(&id)?)
        }
        "posterless" => {
            let rows = lib.lock_store()?.posterless(req.parse::<Limit>()?.limit.clamp(1, 200))?;
            S::ok(rows.into_iter().map(|(id, file)| json!({"id": id, "video_file": file, "path": lib.media.path(&file)})).collect::<Vec<_>>())
        }
        "set_poster" => {
            #[derive(Deserialize)]
            struct SetPoster {
                id: String,
                video_file: String,
                path: String,
            }
            let a: SetPoster = req.parse()?;
            lib.set_poster(&a.id, &a.video_file, Path::new(&a.path))?;
            S::ok(true)
        }
        "export" => {
            #[derive(Deserialize)]
            struct Export {
                #[serde(default)]
                q: String,
                format: String,
                dest: String,
                #[serde(default = "default_true")]
                media: bool,
                /// The page's title (HTML).
                #[serde(default)]
                title: Option<String>,
                /// "en" for an English page (HTML).
                #[serde(default)]
                lang: Option<String>,
            }
            let a: Export = req.parse()?;
            let format = Format::parse(&a.format).ok_or_else(|| CoreError::UnknownFormat(a.format.clone()))?;
            if format == Format::Html {
                let english = a.lang.as_deref().is_some_and(|l| l.starts_with("en"));
                return S::ok(lib.export_html(&a.q, Path::new(&a.dest), a.title.as_deref(), english)?);
            }
            S::ok(lib.export(&a.q, format, Path::new(&a.dest), a.media)?)
        }
        "embed_pending" => S::ok(lib.embed_pending(req.parse::<Limit>()?.limit.clamp(1, 256))?),
        "semantic_search" => {
            let p: Page = req.parse()?;
            S::ok(lib.semantic_search(&p.q, Sort::parse(&p.sort), p.limit.clamp(1, 500), p.offset.max(0))?)
        }
        "related" => {
            #[derive(Deserialize)]
            struct Related {
                id: String,
                #[serde(default = "eight")]
                limit: i64,
            }
            fn eight() -> i64 {
                8
            }
            let a: Related = req.parse()?;
            S::ok(lib.related(&a.id, a.limit)?)
        }
        "summarize" => S::ok(lib.summarize(&req.parse::<Id>()?.id)?),
        // A conversation page (X `TweetDetail`): the author's own thread is
        // added to whichever of its posts the library has. Others are ignored.
        "import_x_thread" => {
            let a: ImportPayload = req.parse()?;
            let payload = match a.payload {
                Value::String(s) => serde_json::from_str(&s).map_err(CoreError::InvalidPayloadJson)?,
                v => v,
            };
            let mut updated = vec![];
            for chain in crate::x::self_threads(&payload) {
                let ids: Vec<String> = chain.iter().map(|i| i.id.clone()).collect();
                let have = lib.lock_store()?.existing_ids(&ids)?;
                // The first saved post of the run holds the rest.
                let Some(owner) = ids.iter().find(|i| have.contains(*i)) else { continue };
                let rest: Vec<Item> = chain.iter().filter(|i| &i.id != owner).cloned().collect();
                if lib.lock_store()?.set_thread(owner, rest)? {
                    updated.push(owner.clone());
                }
            }
            let timeline_ids: Vec<String> = crate::x::parse_timeline(&payload).into_iter().map(|i| i.id).collect();
            let have: HashSet<String> = lib.lock_store()?.existing_ids(&timeline_ids)?.into_iter().collect();
            for (owner, replies) in crate::x::replies_for(&payload, &have) {
                if lib.lock_store()?.set_replies(&owner, replies)? && !updated.contains(&owner) {
                    updated.push(owner);
                }
            }
            if !updated.is_empty() {
                lib.kick_media();
            }
            S::ok(updated)
        }
        "snapshot_pending" => {
            let rows = lib.lock_store()?.snapshot_pending(req.parse::<Limit>()?.limit.clamp(1, 50))?;
            S::ok(rows.into_iter().map(|(id, url)| json!({"id": id, "url": url})).collect::<Vec<_>>())
        }
        "set_snapshot" => {
            #[derive(Deserialize)]
            struct SetSnapshot {
                id: String,
                path: String,
                text: Option<String>,
            }
            let a: SetSnapshot = req.parse()?;
            let bytes = std::fs::read(&a.path).map_err(|source| CoreError::IoPath { path: a.path.clone(), source })?;
            let name = lib.media.put(&bytes, "webarchive")?;
            lib.lock_store()?.set_snapshot(&a.id, &name, a.text.as_deref())?;
            S::ok(name)
        }
        "snapshot_failed" => {
            lib.lock_store()?.snapshot_failed(&req.parse::<Id>()?.id)?;
            S::ok(true)
        }
        "ai_status" => S::ok(lib.ai_status()?),
        "clear_vectors" => {
            lib.lock_store()?.clear_vectors()?;
            S::ok(true)
        }
        "duplicates" => S::ok(lib.duplicates()?),
        "ignore_duplicates" => {
            #[derive(Deserialize)]
            struct Ids {
                ids: Vec<String>,
            }
            lib.ignore_duplicates(&req.parse::<Ids>()?.ids)?;
            S::ok(true)
        }
        "suggest_batch" => {
            #[derive(Deserialize)]
            struct BatchReq {
                #[serde(default)]
                q: String,
                #[serde(default = "ten")]
                limit: i64,
            }
            fn ten() -> i64 {
                10
            }
            let r: BatchReq = req.parse()?;
            S::ok(lib.suggest_batch(&r.q, r.limit)?)
        }
        "apply_batch" => {
            #[derive(Deserialize)]
            struct BatchEntry {
                id: String,
                #[serde(default)]
                tags: Vec<String>,
                #[serde(default)]
                folder_id: Option<i64>,
            }
            #[derive(Deserialize)]
            struct ApplyReq {
                items: Vec<BatchEntry>,
            }
            let a: ApplyReq = req.parse()?;
            let mut store = lib.lock_store()?;
            let mut count = 0usize;
            for entry in a.items {
                let mut touched = false;
                if !entry.tags.is_empty() {
                    store.edit_tags(std::slice::from_ref(&entry.id), &entry.tags, &[])?;
                    touched = true;
                }
                if let Some(fid) = entry.folder_id {
                    store.move_to_folder(&entry.id, Some(fid))?;
                    touched = true;
                }
                if touched {
                    count += 1;
                }
            }
            S::ok(count)
        }
        "article" | "fill_articles" | "highlights" | "highlight" | "today" => {
            super::reader::dispatch::<S>(lib, cmd, req).unwrap_or_else(|| Err(CoreError::UnknownCmd(cmd.to_string())))
        }
        other => match super::sync::dispatch::<S>(lib, other, req) {
            Some(r) => r,
            None => Err(CoreError::UnknownCmd(other.to_string())),
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tweet(id: &str, who: &str, text: &str, reply: Option<&str>, img: Option<&str>) -> Value {
        let mut legacy = json!({"id_str": id, "full_text": text, "created_at": format!("Wed Oct 10 20:19:{id:0>2} +0000 2018")});
        if let (Some(r), Some(o)) = (reply, legacy.as_object_mut()) {
            o.insert("in_reply_to_status_id_str".into(), json!(r));
        }
        if let (Some(u), Some(o)) = (img, legacy.as_object_mut()) {
            o.insert("extended_entities".into(), json!({"media": [{"type": "photo", "media_url_https": u}]}));
        }
        json!({"content": {"itemContent": {"tweet_results": {"result": {
            "rest_id": id, "core": {"user_results": {"result": {"core": {"screen_name": who}}}}, "legacy": legacy}}}}})
    }

    #[test]
    fn threads_join_the_saved_post_and_survive_reimport() {
        let dir = std::env::temp_dir().join(format!("wm-thread-{}", std::process::id()));
        let lib = Library::open(&dir).unwrap_or_else(|_| std::process::abort());
        let first = json!({"data": {"x": [tweet("11", "ali", "zincir başı", None, None)]}});
        handle_value(&lib, json!({"cmd": "import_x", "payload": first.clone()}));
        let detail = json!({"data": {"instructions": [{"entries": [
            tweet("11", "ali", "zincir başı", None, None),
            tweet("12", "ali", "ikinci kısım", Some("11"), Some("https://pbs.twimg.com/media/b.jpg")),
            tweet("13", "veli", "araya giren", Some("12"), None),
            tweet("14", "ali", "üçüncü kısım", Some("12"), None),
        ]}]}});
        let r = handle_value(&lib, json!({"cmd": "import_x_thread", "payload": detail}));
        assert_eq!(r.pointer("/data/0"), Some(&json!("x:11")), "{r}");
        let get = |lib: &Arc<Library>| handle_value(lib, json!({"cmd": "get", "id": "x:11"}));
        let item = get(&lib);
        let texts: Vec<&str> = item
            .pointer("/data/thread")
            .and_then(Value::as_array)
            .map(|a| a.iter().filter_map(|t| t.get("text").and_then(Value::as_str)).collect())
            .unwrap_or_default();
        assert_eq!(texts, vec!["ikinci kısım", "üçüncü kısım"]);
        assert_eq!(item.pointer("/data/media").and_then(Value::as_array).map(Vec::len), Some(1));
        // The bookmark list brings the first post again: the thread stays.
        handle_value(&lib, json!({"cmd": "import_x", "payload": first}));
        let again = get(&lib);
        assert_eq!(again.pointer("/data/thread").and_then(Value::as_array).map(Vec::len), Some(2));
        assert_eq!(again.pointer("/data/media").and_then(Value::as_array).map(Vec::len), Some(1));
        let found = handle_value(&lib, json!({"cmd": "search", "q": "üçüncü"}));
        assert_eq!(found.pointer("/data/total"), Some(&json!(1)));
        lib.shutdown();
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn v12_visual_labels_hashes_transcripts_and_batch_ai() {
        let dir = std::env::temp_dir().join(format!("wm-v12-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let lib = Library::open(&dir).unwrap_or_else(|_| std::process::abort());
        handle_value(
            &lib,
            json!({
                "cmd": "import_items",
                "items": [
                    {"platform": "web", "url": "https://example.com/a", "author_handle": "ali", "text": "foto bir"},
                    {"platform": "web", "url": "https://example.com/b", "author_handle": "ali", "text": "foto iki"},
                    {"platform": "web", "url": "https://example.com/c", "author_handle": "ali", "text": "önceki"}
                ]
            }),
        );
        let all = handle_value(&lib, json!({"cmd": "search", "q": "", "sort": "saved_oldest"}));
        let items = all.pointer("/data/items").and_then(Value::as_array).cloned().unwrap_or_default();
        assert_eq!(items.len(), 3, "{all}");
        let aid = items.first().and_then(|v| v.get("id")).and_then(Value::as_str).unwrap_or_default().to_string();
        let bid = items.get(1).and_then(|v| v.get("id")).and_then(Value::as_str).unwrap_or_default().to_string();
        let cid = items.get(2).and_then(|v| v.get("id")).and_then(Value::as_str).unwrap_or_default().to_string();
        assert!(!aid.is_empty() && !bid.is_empty() && !cid.is_empty());

        // set_ocr saves labels + imghash, making labels searchable and items visually related/duplicate.
        let r = handle_value(
            &lib,
            json!({
                "cmd": "set_ocr",
                "id": aid,
                "text": "ekran görüntüsü",
                "labels": "kedi cat evcil",
                "imghash": 0x0F0F_0F0F_0F0F_0F0Fi64
            }),
        );
        assert_eq!(r.get("ok"), Some(&json!(true)));
        let r2 = handle_value(
            &lib,
            json!({
                "cmd": "set_ocr",
                "id": bid,
                "text": "",
                "labels": "kedi",
                "imghash": 0x0F0F_0F0F_0F0F_0F0Ei64
            }),
        );
        assert_eq!(r2.get("ok"), Some(&json!(true)));

        // Search finds visual label & extra transcript appended via append_extra.
        let by_label = handle_value(&lib, json!({"cmd": "search", "q": "evcil"}));
        assert_eq!(by_label.pointer("/data/total"), Some(&json!(1)));

        let app = handle_value(&lib, json!({"cmd": "append_extra", "id": bid, "text": "tarifte tarçın var"}));
        assert_eq!(app.get("ok"), Some(&json!(true)));
        let by_speech = handle_value(&lib, json!({"cmd": "search", "q": "tarçın"}));
        assert_eq!(by_speech.pointer("/data/total"), Some(&json!(1)));

        // Related & duplicates by imghash (Hamming distance == 1 <= 4 <= 10).
        let rel = handle_value(&lib, json!({"cmd": "related", "id": aid, "limit": 8}));
        assert_eq!(rel.pointer("/data/0/id"), Some(&json!(bid)));
        let dups = handle_value(&lib, json!({"cmd": "duplicates"}));
        let has_media_dup =
            dups.pointer("/data").and_then(Value::as_array).is_some_and(|arr| arr.iter().any(|g| g.get("reason") == Some(&json!("media"))));
        assert!(has_media_dup, "{dups}");

        // Folder-history batch suggestions and apply_batch.
        let folder = handle_value(&lib, json!({"cmd": "add_folder", "name": "Örnekler"}));
        let fid = folder.pointer("/data/id").and_then(Value::as_i64);
        assert!(fid.is_some());
        handle_value(&lib, json!({"cmd": "move_to_folder", "id": cid, "folder_id": fid}));
        handle_value(&lib, json!({"cmd": "set_tags", "id": cid, "tags": ["arsiv"]}));
        let sug = handle_value(&lib, json!({"cmd": "suggest_batch", "q": "", "limit": 10}));
        let suggestions = sug.pointer("/data").and_then(Value::as_array).cloned().unwrap_or_default();
        assert_eq!(suggestions.len(), 2, "{sug}");
        let entries: Vec<Value> =
            suggestions.iter().map(|s| json!({"id": s.get("id"), "tags": ["örnek"], "folder_id": s.get("folder_id")})).collect();
        let applied = handle_value(&lib, json!({"cmd": "apply_batch", "items": entries}));
        assert_eq!(applied.pointer("/data"), Some(&json!(2)));

        // add_note & save_link with folder_id
        let note = handle_value(
            &lib,
            json!({
                "cmd": "add_note",
                "title": "Fikir",
                "text": "Hızlı not içeriği",
                "tags": ["notlar"],
                "folder_id": fid
            }),
        );
        assert_eq!(note.get("ok"), Some(&json!(true)), "{note}");
        assert_eq!(note.pointer("/data/platform"), Some(&json!("local")));
        assert_eq!(note.pointer("/data/folder_id"), Some(&json!(fid)));
        let saved = handle_value(
            &lib,
            json!({
                "cmd": "save_link",
                "url": "https://example.com/with-folder",
                "tags": ["web"],
                "folder_id": fid
            }),
        );
        assert_eq!(saved.pointer("/data/new"), Some(&json!(true)));
        let saved_id = saved.pointer("/data/id").and_then(Value::as_str).unwrap_or_default();
        let fetched = handle_value(&lib, json!({"cmd": "get", "id": saved_id}));
        assert_eq!(fetched.pointer("/data/folder_id"), Some(&json!(fid)));

        lib.shutdown();
        let _ = std::fs::remove_dir_all(&dir);
    }
}
