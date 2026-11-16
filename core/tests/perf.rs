//! How the library holds up at scale. Not part of the normal test run:
//!
//!   WM_PERF_N=50000 cargo test --release --test perf -- --ignored --nocapture
//!
//! Builds a library of N posts (text, authors, tags, folders, links, picture
//! names, image fingerprints, a few highlights) and times what the apps do
//! most: opening, searching, paging, filters, Today, related, duplicates,
//! exports and a sync with its log compaction.

use std::sync::Arc;
use std::time::Instant;

use serde_json::{Value, json};
use wroopmark_core::api::{Library, handle_value};

const WORDS: [&str; 40] = [
    "rust",
    "kahve",
    "tarif",
    "yapay",
    "zeka",
    "tasarım",
    "tipografi",
    "uzay",
    "teleskop",
    "satürn",
    "mercan",
    "deniz",
    "istanbul",
    "kyoto",
    "seyahat",
    "fotoğraf",
    "video",
    "müzik",
    "kitap",
    "okuma",
    "yazılım",
    "swift",
    "apple",
    "macbook",
    "iphone",
    "kamera",
    "dağ",
    "orman",
    "şehir",
    "gece",
    "sabah",
    "çay",
    "baklava",
    "ekmek",
    "maya",
    "spor",
    "koşu",
    "bisiklet",
    "film",
    "dizi",
];

fn call(lib: &Arc<Library>, req: Value) -> Value {
    let r = handle_value(lib, req);
    assert_eq!(r.get("ok"), Some(&json!(true)), "{r}");
    r.get("data").cloned().unwrap_or(Value::Null)
}

fn timed<T>(label: &str, f: impl FnOnce() -> T) -> T {
    let t = Instant::now();
    let out = f();
    println!("{label:<44} {:>9.1} ms", t.elapsed().as_secs_f64() * 1000.0);
    out
}

/// A cheap deterministic generator (no extra dependency).
struct Rng(u64);
impl Rng {
    fn next(&mut self) -> u64 {
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 7;
        self.0 ^= self.0 << 17;
        self.0
    }
    fn pick<'a>(&mut self, xs: &[&'a str]) -> &'a str {
        xs[(self.next() % xs.len() as u64) as usize]
    }
}

#[test]
#[ignore]
fn large_library() {
    let n: usize = std::env::var("WM_PERF_N").ok().and_then(|v| v.parse().ok()).unwrap_or(50_000);
    let root = std::env::temp_dir().join(format!("wm-perf-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&root);
    let lib = Library::open(&root.join("lib")).unwrap_or_else(|_| std::process::abort());
    let mut rng = Rng(0x9E37_79B9_7F4A_7C15);
    println!("\n== {n} posts");

    timed("import (batches of 500)", || {
        let platforms = ["x", "tiktok", "web", "reddit", "youtube", "instagram"];
        for chunk in 0..n.div_ceil(500) {
            let items: Vec<Value> = (chunk * 500..((chunk + 1) * 500).min(n))
                .map(|i| {
                    let words: Vec<&str> = (0..24).map(|_| rng.pick(&WORDS)).collect();
                    let p = platforms[i % platforms.len()];
                    let url = match p {
                        "x" => format!("https://x.com/u{}/status/{}", i % 900, 1_000_000_000 + i),
                        "tiktok" => format!("https://www.tiktok.com/@u{}/video/{}", i % 900, 7_000_000_000_000_000_000u64 + i as u64),
                        "reddit" => format!("https://www.reddit.com/r/sub{}/comments/a{i}/t/", i % 50),
                        "youtube" => format!("https://www.youtube.com/watch?v=v{i:010}"),
                        "instagram" => format!("https://www.instagram.com/p/P{i:09}/"),
                        _ => format!("https://site{}.example.com/makale/{i}", i % 400),
                    };
                    json!({
                        "platform": p,
                        "url": url,
                        "author_handle": format!("u{}", i % 900),
                        "text": format!("{} https://link{}.example.org/{}", words.join(" "), i % 3000, i),
                        "created_at": 1_600_000_000 + (i as i64) * 1700,
                        "saved_at": 1_650_000_000 + (i as i64) * 900,
                        "media": [{"kind": if i % 3 == 0 { "video" } else { "image" }, "url": format!("https://cdn.example/{i}.jpg")}],
                    })
                })
                .collect();
            let tags = vec![format!("konu/{}", WORDS[chunk % 10])];
            call(&lib, json!({"cmd": "import_items", "items": items, "tags": tags}));
        }
    });

    let folders: Vec<i64> = (0..40)
        .map(|i| {
            call(&lib, json!({"cmd": "add_folder", "name": format!("Klasör {}/Alt {}", i / 8, i % 8)})).get("id").and_then(Value::as_i64).unwrap_or(0)
        })
        .collect();
    let ids: Vec<String> = timed("list every id (search, 500 a page)", || {
        let mut ids = vec![];
        let mut offset = 0;
        loop {
            let page = call(&lib, json!({"cmd": "search", "q": "", "sort": "saved", "limit": 500, "offset": offset}));
            let items = page.get("items").and_then(Value::as_array).cloned().unwrap_or_default();
            if items.is_empty() {
                break;
            }
            offset += items.len();
            ids.extend(items.iter().filter_map(|i| i.get("id").and_then(Value::as_str).map(str::to_string)));
        }
        ids
    });
    assert_eq!(ids.len(), n);
    timed("put a fifth in folders (one call each)", || {
        for (i, id) in ids.iter().enumerate().filter(|(i, _)| i % 5 == 0) {
            call(&lib, json!({"cmd": "move_to_folder", "id": id, "folder_id": folders[i % folders.len()]}));
        }
    });
    timed("OCR text, labels, fingerprints (a third)", || {
        for (i, id) in ids.iter().enumerate().filter(|(i, _)| i % 3 == 0) {
            let hash = (rng.next() & 0x7FFF_FFFF_FFFF_FFFF) as i64;
            call(&lib, json!({"cmd": "set_ocr", "id": id, "text": format!("ekran {}", WORDS[i % 40]), "labels": "food screenshot", "imghash": hash}));
        }
    });
    timed("highlights on 500 posts", || {
        for id in ids.iter().take(500) {
            call(&lib, json!({"cmd": "highlight", "id": id, "quote": "rust", "note": "önemli"}));
        }
    });

    println!("-- reads");
    timed("stats", || call(&lib, json!({"cmd": "stats"})));
    timed("first page, newest (60)", || call(&lib, json!({"cmd": "search", "q": "", "limit": 60})));
    timed("page 400 of 60 (offset 24000)", || call(&lib, json!({"cmd": "search", "q": "", "limit": 60, "offset": 24_000})));
    timed("word: \"kahve\"", || call(&lib, json!({"cmd": "search", "q": "kahve", "limit": 60})));
    timed("two words: \"yapay zeka\"", || call(&lib, json!({"cmd": "search", "q": "yapay zeka", "limit": 60})));
    timed("phrase: \"\\\"deniz mercan\\\"\"", || call(&lib, json!({"cmd": "search", "q": "\"deniz mercan\"", "limit": 60})));
    timed("prefix-ish word: \"tasar\"", || call(&lib, json!({"cmd": "search", "q": "tasar", "limit": 60})));
    timed("filters: platform:x has:video tag:konu", || call(&lib, json!({"cmd": "search", "q": "platform:x has:video tag:konu", "limit": 60})));
    timed("from:@u42", || call(&lib, json!({"cmd": "search", "q": "from:@u42", "limit": 60})));
    timed("folder:<id> (with subfolders)", || call(&lib, json!({"cmd": "search", "q": format!("folder:{}", folders[0]), "limit": 60})));
    timed("is:untagged sort:random", || call(&lib, json!({"cmd": "search", "q": "is:untagged", "sort": "random:7", "limit": 60})));
    timed("has:highlight", || call(&lib, json!({"cmd": "search", "q": "has:highlight", "limit": 60})));
    timed("tags", || call(&lib, json!({"cmd": "tags"})));
    timed("folders", || call(&lib, json!({"cmd": "folders"})));
    timed("today", || call(&lib, json!({"cmd": "today"})));
    timed("get one post", || call(&lib, json!({"cmd": "get", "id": ids[n / 2]})));
    timed("related (fingerprints, no vectors)", || call(&lib, json!({"cmd": "related", "id": ids[0], "limit": 6})));
    timed("links (pool, 60)", || call(&lib, json!({"cmd": "links", "q": "", "limit": 60})));
    timed("needs_video", || call(&lib, json!({"cmd": "needs_video", "limit": 30})));
    timed("duplicates", || call(&lib, json!({"cmd": "duplicates"})));

    println!("-- writes and exports");
    timed("edit tags on 1000 at once", || call(&lib, json!({"cmd": "edit_tags", "ids": ids[..1000], "add": ["toplu"]})));
    timed("export html, folder (no pictures on disk)", || {
        call(&lib, json!({"cmd": "export", "format": "html", "q": format!("folder:{}", folders[1]), "dest": root.join("out"), "title": "perf"}))
    });
    timed("export csv, everything", || call(&lib, json!({"cmd": "export", "format": "csv", "q": "", "dest": root.join("out")})));

    timed("delete 300 posts (one call each)", || {
        for id in ids.iter().skip(n - 300) {
            call(&lib, json!({"cmd": "delete", "id": id}));
        }
    });

    println!("-- sync");
    let shared = root.join("shared");
    timed("sync_enable (first push, whole library)", || call(&lib, json!({"cmd": "sync_enable", "dir": shared, "media": "none"})));
    timed("touch 2000 notes", || {
        for id in ids.iter().take(2000) {
            call(&lib, json!({"cmd": "set_note", "id": id, "note": "not"}));
        }
    });
    timed("sync_now (push 2000, maybe compact)", || call(&lib, json!({"cmd": "sync_now"})));
    let other = Library::open(&root.join("other")).unwrap_or_else(|_| std::process::abort());
    timed("second device: first sync (pull all)", || call(&other, json!({"cmd": "sync_enable", "dir": shared, "media": "none"})));
    let size: u64 = std::fs::read_dir(shared.join("ops"))
        .map(|d| {
            d.flatten()
                .flat_map(|dev| std::fs::read_dir(dev.path()).into_iter().flatten().flatten())
                .filter_map(|f| f.metadata().ok())
                .map(|m| m.len())
                .sum()
        })
        .unwrap_or(0);
    println!("{:<44} {:>9.1} MB", "sync logs on disk", size as f64 / 1e6);
    let db = std::fs::metadata(root.join("lib").join("library.sqlite")).map(|m| m.len()).unwrap_or(0);
    println!("{:<44} {:>9.1} MB", "library.sqlite", db as f64 / 1e6);

    timed("reopen the library (close + open)", || {
        lib.shutdown();
        drop(lib);
        Library::open(&root.join("lib")).unwrap_or_else(|_| std::process::abort())
    })
    .shutdown();
    other.shutdown();
    let _ = std::fs::remove_dir_all(&root);
}
