#!/usr/bin/env python3
"""Builds the landing page in English (docs/index.html) and Turkish
(docs/tr.html) from one layout, so the two never drift apart.

    python3 docs/_src/build.py

Jekyll skips folders starting with "_", so this file is not published.
"""
import html
import json
from pathlib import Path

DOCS = Path(__file__).resolve().parent.parent
SITE = "https://f0rknturkoglu.github.io/wroopmark/"
REPO = "https://github.com/f0rknturkoglu/wroopmark"
DOWNLOAD = REPO + "/releases/latest"
VERSION = "1.7.1"

T = {
    "en": {
        "file": "index.html", "url": SITE, "other": "tr", "other_name": "Türkçe", "other_href": "tr.html",
        "title": "wroopmark — offline bookmark manager and read-later archive for Mac, iPhone and iPad",
        "desc": "Save posts, videos, articles and pictures from any app into one archive on your own devices. A native Mac app that sits at 0% CPU when idle, plus iPhone and iPad. Offline, searchable, no account, no server.",
        "og_title": "wroopmark — your saved posts, offline and searchable",
        "og_desc": "One archive for what you save on X, TikTok, Instagram, Reddit, YouTube, Bluesky, Threads and the web. Native on Mac, iPhone and iPad. No account, no server.",
        "nav": [("#mac", "Mac"), ("#iphone", "iPhone"), ("#search", "Search"), ("#sync", "Sync"), ("#private", "Privacy"), ("#light", "Speed")],
        "download": "Download", "download_mac": "Download for Mac", "see_iphone": "See it on iPhone",
        "h1": "Everything you saved, in one archive you own.",
        "lead": "Posts, videos, articles and pictures from X, TikTok, Instagram, Reddit, YouTube and the web, kept on your Mac, iPhone and iPad. Offline, searchable, and on nobody's server, because there isn't one.",
        "cta_note": f"Free and open source · macOS 26 or later · 15 MB, signed and notarized by Apple · v{VERSION}",
        "hero_mac_alt": "wroopmark on Mac: saved pages in a grid, and the selected item's summary, folder and tags",
        "hero_phone_alt": "wroopmark on iPhone: the library list",
        "scroll_hint": "Scroll to take the tour",
        "saves_from": "Saves from",
        "platforms": ["X", "TikTok", "Instagram", "Reddit", "YouTube", "Bluesky", "Threads", "Pinterest", "Hacker News", "GitHub", "arXiv", "any web page"],
        "stats": [("0.0", "% CPU", "when it sits open and idle on a Mac", None),
                  ("110", " MB", "of memory with 50,000 posts in the library", "~"),
                  ("35", " ms", "at most to search 50,000 posts", "< "),
                  ("0", " servers", "no account, no tracking, nothing to sign up for", None)],
        "intro": "You save things everywhere, and they scatter: five apps, half of them unsearchable, and the post you wanted is gone the day its author deletes it. <b>wroopmark keeps the text, the pictures and the videos on your own devices</b>, so they stay readable offline and outlive the original.",
        "mac_eyebrow": "Tour · Mac", "mac_h2": "A real Mac app, not a web page in a box.",
        "mac_intro": "Scroll, and the window below does what the app does.",
        "mac_steps": [
            ("Everything in one grid", "Posts, pages and pictures from every app, picture first, newest on top. Folders, nested tags and platforms in the sidebar."),
            ("Summary, tags, folder", "Select anything: an on-device summary, suggested tags and its folder appear beside it. Apple's models, on your Mac; nothing is sent anywhere."),
            ("Search with filters", "Type <code>tag:recipes</code>, <code>from:@someone</code>, <code>has:video</code> or plain words. Text inside pictures and speech in videos count too."),
            ("Today", "What you saved on this day in past years, and five picks from the archive, so old saves come back to you."),
            ("Triage", "Saves come one at a time: delete, keep, or drop into a suggested folder. Keys <kbd>←</kbd> <kbd>→</kbd> <kbd>1</kbd>–<kbd>2</kbd>, and undo."),
            ("Every picture", "A gallery of every image you ever saved. Similar-picture search finds the rest of a series."),
            ("Read offline", "A clean reader built from the page's own copy: themes, text size, read aloud, highlights and notes. It works after the site is gone."),
            ("Light or dark", "Follow your Mac, or pick one. <kbd>⌘N</kbd> to add, <kbd>Space</kbd> to preview, <kbd>⌃⌥⌘S</kbd> to save from any app."),
        ],
        "phone_eyebrow": "Tour · iPhone", "phone_h2": "Share → wroopmark, from any app.",
        "phone_intro": "It works on its own; the Mac only makes it faster.",
        "phone_steps": [
            ("Share from anywhere", "In X, Safari, Instagram or any app: Share → wroopmark. Add it to your favorites once and it's always one tap."),
            ("Saved", "The link is saved at once. Title, text and pictures arrive by themselves, even if you were offline."),
            ("Pictures, tags, folder, note", "Every save keeps its pictures. Tag it, file it, write a note, or put your own video from Photos on the post."),
            ("Read it, highlight it", "The offline reader, with highlights that sync and read-aloud controls on the Lock Screen."),
            ("Sort with a swipe", "Triage on the phone: swipe left to delete, right to keep, tap a suggested folder."),
        ],
        "share_title": "Kyoto - Wikipedia", "share_url": "en.wikipedia.org",
        "share_apps": ["wroopmark", "Notes", "Mail", "More"], "share_acts": ["Copy", "Add Bookmark"],
        "island": "Saved to wroopmark",
        "search_eyebrow": "Search", "search_h2": "Find it again, however you remember it.",
        "search_ph": "Search…",
        "search_tokens": ["espresso", "tag:recipes", "from:@nasa", "has:image", "after:2024", "\"crema\"", "coffee from Italy"],
        "search_steps": [
            ("Words", "Any word from the title, the text, your notes and highlights, or the text inside pictures. Case and Turkish ı/i don't matter."),
            ("tag:", "Only posts with a tag. Nested tags like <code>reading/tech</code> include their children."),
            ("from:@", "Only posts by one person, on any platform."),
            ("has:", "<code>has:image</code>, <code>has:video</code>, <code>has:highlight</code>: only posts with pictures, videos or your highlights."),
            ("after: · before:", "Dates as loose as you like: <code>after:2024</code>, <code>before:2025-06</code>."),
            ("\"Exact phrases\"", "Quotes for words in that order. Also <code>site:github.com</code>, <code>platform:x</code>, <code>folder:Name</code>, <code>is:untagged</code>."),
            ("By meaning", "Turn on meaning search and describe it instead: \"coffee from Italy\" finds the espresso page. On-device, in your language."),
        ],
        "sync_eyebrow": "Sync", "sync_h2": "Every device, no server.",
        "sync_steps": [
            ("A folder you own", "Pick a folder in your own iCloud Drive. That's the whole setup, and it's also your backup."),
            ("Each device writes its own log", "Your Mac only appends to its own file. Nothing is ever written by two devices at once, so nothing gets corrupted."),
            ("…and reads the others'", "Your iPhone reads what the Mac wrote and the other way round. Edits merge field by field."),
            ("Pictures and videos come along", "Media is stored once, by its fingerprint. The Mac brings videos to the phone through the same folder."),
            ("New phone? Same folder.", "Choose the same folder on a new device and the whole archive comes back."),
        ],
        "sync_labels": {"mac": "Mac", "folder": "iCloud Drive / wroopmark", "phone": "iPhone", "phone2": "New iPhone", "log": "ops/mac/2026-11.jsonl", "media": "media/"},
        "private_eyebrow": "Privacy",
        "private_text": "No account. No server. No ads. No tracking. Your archive is a folder on your own disk, and it stays readable even if every site it came from goes away.",
        "private_link": "Read the privacy policy",
        "light_eyebrow": "Light & fast", "light_h2": "Idle means idle.",
        "light_intro": "No Electron, no background service, no browser engine kept warm. When the window is open and you aren't doing anything, wroopmark uses no CPU. Text recognition and on-device AI run in small helper processes only while they have work, and you can pause them in Settings.",
        "cpu_label": "CPU over one minute, window open, idle", "cpu_value": "0.0%",
        "table_head": ("Measured on a Mac", "Result"),
        "table": [
            ("CPU, window open, idle (a 50,000-post library, and a real archive after a day of use)", "0.0%"),
            ("Memory, 50,000 posts, window open", "~110 MB"),
            ("Memory after a day of everyday use, a screen full of pictures", "~280 MB"),
            ("Open the library", "5 ms"),
            ("First page of the newest posts", "0.6 ms"),
            ("Word or phrase search across 50,000 posts", "7–21 ms"),
            ("Filters (<code>platform:x has:video tag:…</code>, <code>from:@…</code>, folders)", "3–32 ms"),
            ("Download / installed app", "15 MB / 29 MB"),
        ],
        "fine": "Mac with M4 Pro, macOS 27.2, wroopmark 1.7. Memory is the system's “footprint” figure; CPU is from <code>top</code> over a minute. After a big import the library is indexed once in the background (text recognition, search by meaning), which uses CPU until it is done. Timings come from the repository's own test, <code>WM_PERF_N=50000 cargo test --release --test perf -- --ignored</code>, so you can run it yourself.",
        "ipad_eyebrow": "iPad", "ipad_h2": "Three columns on iPad.", "ipad_text": "Scopes, the list and the post side by side, with the same reader, feed and Triage.",
        "ipad_alt": "wroopmark on iPad in three columns",
        "more_eyebrow": "Everything else", "more_h2": "Made to keep, not to scroll past.",
        "cards": [
            ("Watch your saves", "Saved videos and posts full screen, one after another, with picture-in-picture, AirPlay and playback speed."),
            ("Bring it all in", "Data downloads from TikTok, Instagram, X, Threads and Reddit, browser bookmarks, Pocket and Raindrop CSV."),
            ("Browser extension", "Chrome, Brave, Arc, Edge, Vivaldi and Safari: bookmarks and saved posts flow in as you browse."),
            ("Keep it tidy", "Rules that file new saves, duplicates, a link pool with broken-link checks."),
            ("Take it with you", "Markdown (Obsidian-ready, with pictures), CSV, JSON, or one HTML page you can send to anyone."),
            ("For AI agents", "A local MCP server lets agents such as Claude search and read your archive, on your machine."),
        ],
        "cmp_eyebrow": "How it compares", "cmp_h2": "It keeps the post itself, not just the link.",
        "cmp_head": ["", "wroopmark", "Read-later apps", "Bookmark managers", "Self-hosted archivers"],
        "cmp_rows": [
            ("Keeps the post's pictures and videos", "✅", "—", "—", "some"),
            ("Social saves (X, TikTok, Instagram, Reddit, Bluesky, Threads)", "✅", "—", "links only", "some"),
            ("Offline, survives deletion", "✅", "articles", "—", "✅"),
            ("Search inside pictures and video speech", "✅", "—", "—", "—"),
            ("On-device AI", "✅", "cloud", "cloud", "external API"),
            ("No account, no server", "✅", "—", "—", "needs a server"),
            ("Native Mac, iPhone and iPad apps", "✅", "✅", "✅", "web"),
        ],
        "get_eyebrow": "Get it", "get_h2": "Free, private, yours.",
        "get": [
            ("Mac", "macOS 26 or later. Signed and notarized by Apple; it keeps itself up to date and checks every update's signature first.", "Download for Mac", DOWNLOAD),
            ("iPhone and iPad", "Coming to the App Store. The app walks you through the Share menu, the Safari extension and iCloud backup on first launch.", None, None),
            ("Open source", "MIT licensed. Read the code, build it yourself, or share an idea.", "Source on GitHub", REPO),
        ],
        "footer": "© 2026 Furkan Türkoğlu · MIT License", "privacy": "Privacy", "support": "Support",
        "credit": "Screenshots show Wikipedia articles (CC BY-SA 4.0) in a demo library.",
        "privacy_href": "privacy.html", "support_href": "support.html",
    },
    "tr": {
        "file": "tr.html", "url": SITE + "tr.html", "other": "en", "other_name": "English", "other_href": "./",
        "title": "wroopmark — Mac, iPhone ve iPad için çevrimdışı yer imi ve sonra oku arşivi",
        "desc": "Her uygulamadan gönderi, video, makale ve görsel kaydet; hepsi kendi cihazındaki tek bir arşivde. Boştayken yüzde 0 işlemci kullanan yerel bir Mac uygulaması, iPhone ve iPad. İnternetsiz, aranabilir, hesap yok, sunucu yok.",
        "og_title": "wroopmark — kaydettiklerin, internetsiz ve aranabilir",
        "og_desc": "X, TikTok, Instagram, Reddit, YouTube, Bluesky, Threads ve web'de kaydettiklerin tek arşivde. Mac, iPhone ve iPad'de yerel uygulama. Hesap yok, sunucu yok.",
        "nav": [("#mac", "Mac"), ("#iphone", "iPhone"), ("#search", "Arama"), ("#sync", "Eşitleme"), ("#private", "Gizlilik"), ("#light", "Hız")],
        "download": "İndir", "download_mac": "Mac için indir", "see_iphone": "iPhone'da gör",
        "h1": "Kaydettiğin her şey, sana ait tek bir arşivde.",
        "lead": "X, TikTok, Instagram, Reddit, YouTube ve web'den gönderiler, videolar, makaleler ve görseller Mac'inde, iPhone'unda ve iPad'inde durur. İnternetsiz, aranabilir ve kimsenin sunucusunda değil, çünkü sunucu yok.",
        "cta_note": f"Ücretsiz ve açık kaynak · macOS 26 ve sonrası · 15 MB, Apple tarafından imzalı ve onaylı · v{VERSION}",
        "hero_mac_alt": "Mac'te wroopmark: kayıtlar bir ızgarada, sağda seçili kaydın özeti, klasörü ve etiketleri",
        "hero_phone_alt": "iPhone'da wroopmark: kütüphane listesi",
        "scroll_hint": "Turu görmek için kaydır",
        "saves_from": "Şuralardan kaydeder",
        "platforms": ["X", "TikTok", "Instagram", "Reddit", "YouTube", "Bluesky", "Threads", "Pinterest", "Hacker News", "GitHub", "arXiv", "her web sayfası"],
        "stats": [("0,0", " işlemci", "Mac'te açık dururken, sen bir şey yapmıyorken", "%"),
                  ("110", " MB", "bellek, kütüphanede 50.000 gönderi varken", "~"),
                  ("35", " ms", "en fazla, 50.000 gönderide arama", "< "),
                  ("0", " sunucu", "hesap yok, takip yok, üye olunacak bir şey yok", None)],
        "intro": "Her yerde bir şeyler kaydediyorsun ve hepsi dağılıyor: beş ayrı uygulama, yarısında arama yok ve aradığın gönderi sahibi sildiği gün kayboluyor. <b>wroopmark metni, görselleri ve videoları kendi cihazlarında saklar</b>; internetsiz okunur, asıl gönderi silinse de kalır.",
        "mac_eyebrow": "Tur · Mac", "mac_h2": "Gerçek bir Mac uygulaması, kutuya konmuş bir web sayfası değil.",
        "mac_intro": "Kaydır; aşağıdaki pencere uygulamanın yaptığını yapsın.",
        "mac_steps": [
            ("Her şey tek ızgarada", "Her uygulamadan gönderiler, sayfalar ve görseller; önce görsel, en yeni en üstte. Kenar çubuğunda klasörler, iç içe etiketler ve platformlar."),
            ("Özet, etiket, klasör", "Bir kaydı seç: cihazda yazılmış özeti, önerilen etiketleri ve klasörü yanında belirir. Apple'ın modelleri, senin Mac'inde; hiçbir şey dışarı gitmez."),
            ("Süzgeçli arama", "<code>tag:tarif</code>, <code>from:@biri</code>, <code>has:video</code> ya da düz kelimeler yaz. Görsellerdeki yazı ve videolardaki konuşma da aranır."),
            ("Bugün", "Geçmiş yıllarda bugün kaydettiklerin ve arşivden beş seçki; eski kayıtlar sana geri döner."),
            ("Ayıkla", "Kayıtlar tek tek gelir: sil, sakla ya da önerilen klasöre at. <kbd>←</kbd> <kbd>→</kbd> <kbd>1</kbd>–<kbd>2</kbd> tuşları ve geri al."),
            ("Bütün görseller", "Kaydettiğin her görsel tek galeride. Benzer görsel araması bir serinin gerisini bulur."),
            ("İnternetsiz oku", "Sayfanın kendi kopyasından sade okuyucu: tema, yazı boyutu, sesli okuma, vurgu ve not. Site kapansa da çalışır."),
            ("Açık ya da koyu", "Mac'ini izlesin ya da birini seç. <kbd>⌘N</kbd> ekle, <kbd>Boşluk</kbd> önizle, <kbd>⌃⌥⌘S</kbd> her uygulamadan kaydet."),
        ],
        "phone_eyebrow": "Tur · iPhone", "phone_h2": "Her uygulamadan Paylaş → wroopmark.",
        "phone_intro": "Tek başına çalışır; Mac yalnızca hızlandırır.",
        "phone_steps": [
            ("Her yerden paylaş", "X'te, Safari'de, Instagram'da ya da herhangi bir uygulamada: Paylaş → wroopmark. Bir kez sık kullanılanlara ekle, hep tek dokunuş."),
            ("Kaydedildi", "Bağlantı hemen kaydedilir. Başlık, metin ve görseller kendiliğinden gelir; internet yokken bile."),
            ("Görsel, etiket, klasör, not", "Her kayıt görselleriyle kalır. Etiketle, klasöre koy, not yaz ya da Fotoğraflar'dan kendi videonu gönderiye ekle."),
            ("Oku, vurgula", "İnternetsiz okuyucu; eşitlenen vurgular ve Kilit Ekranı'nda sesli okuma kontrolleri."),
            ("Kaydırarak ayıkla", "Telefonda Ayıkla: sola kaydır sil, sağa kaydır sakla, önerilen klasöre dokun."),
        ],
        "share_title": "Kyoto - Vikipedi", "share_url": "tr.wikipedia.org",
        "share_apps": ["wroopmark", "Notlar", "Posta", "Diğer"], "share_acts": ["Kopyala", "Yer imi ekle"],
        "island": "wroopmark'a kaydedildi",
        "search_eyebrow": "Arama", "search_h2": "Nasıl hatırlıyorsan öyle bul.",
        "search_ph": "Ara…",
        "search_tokens": ["espresso", "tag:tarif", "from:@nasa", "has:image", "after:2024", "\"crema\"", "İtalyan kahvesi"],
        "search_steps": [
            ("Kelimeler", "Başlıktan, metinden, notlarından, vurgularından ya da görsellerin içindeki yazıdan herhangi bir kelime. Büyük-küçük harf ve ı/i fark etmez."),
            ("tag:", "Yalnızca o etiketli kayıtlar. <code>okuma/teknoloji</code> gibi iç içe etiketler altlarını da kapsar."),
            ("from:@", "Yalnızca tek bir kişinin gönderileri, hangi platformda olursa olsun."),
            ("has:", "<code>has:image</code>, <code>has:video</code>, <code>has:highlight</code>: yalnızca görselli, videolu ya da vurguladığın kayıtlar."),
            ("after: · before:", "Tarihler istediğin kadar kaba: <code>after:2024</code>, <code>before:2025-06</code>."),
            ("\"Tam öbek\"", "Kelimeler o sırayla geçsin diye tırnak. Ayrıca <code>site:github.com</code>, <code>platform:x</code>, <code>folder:Ad</code>, <code>is:untagged</code>."),
            ("Anlamına göre", "Anlam aramasını aç ve tarif et: \"İtalyan kahvesi\" espresso sayfasını bulur. Cihazda, senin dilinde."),
        ],
        "sync_eyebrow": "Eşitleme", "sync_h2": "Bütün cihazlar, sunucu olmadan.",
        "sync_steps": [
            ("Senin klasörün", "Kendi iCloud Drive'ında bir klasör seç. Kurulumun hepsi bu; aynı zamanda yedeğin."),
            ("Her cihaz kendi günlüğüne yazar", "Mac yalnızca kendi dosyasına ekler. İki cihaz aynı dosyaya hiç yazmaz, bu yüzden hiçbir şey bozulmaz."),
            ("…ve diğerlerininkini okur", "iPhone, Mac'in yazdığını okur, Mac de iPhone'unkini. Değişiklikler alan alan birleşir."),
            ("Görseller ve videolar da gelir", "Medya parmak iziyle bir kez saklanır. Mac videoları aynı klasör üzerinden telefona getirir."),
            ("Yeni telefon mu? Aynı klasör.", "Yeni cihazda aynı klasörü seç; bütün arşiv geri gelir."),
        ],
        "sync_labels": {"mac": "Mac", "folder": "iCloud Drive / wroopmark", "phone": "iPhone", "phone2": "Yeni iPhone", "log": "ops/mac/2026-11.jsonl", "media": "media/"},
        "private_eyebrow": "Gizlilik",
        "private_text": "Hesap yok. Sunucu yok. Reklam yok. Takip yok. Arşivin kendi diskindeki bir klasör; geldiği bütün siteler kapansa bile okunmaya devam eder.",
        "private_link": "Gizlilik politikasını oku",
        "light_eyebrow": "Hafif ve hızlı", "light_h2": "Boştayken gerçekten boşta.",
        "light_intro": "Electron yok, arka plan servisi yok, sıcak tutulan bir tarayıcı motoru yok. Pencere açıkken bir şey yapmıyorsan wroopmark işlemci kullanmaz. Görsellerde yazı tanıma ve cihazdaki yapay zekâ küçük yardımcı süreçlerde, yalnızca iş varken çalışır; Ayarlar'dan duraklatılır.",
        "cpu_label": "Bir dakika boyunca işlemci, pencere açık, boşta", "cpu_value": "%0,0",
        "table_head": ("Mac'te ölçülen", "Sonuç"),
        "table": [
            ("İşlemci, pencere açık, boşta (50.000 gönderilik kütüphane ve bir günlük kullanımdan sonra gerçek bir arşiv)", "%0,0"),
            ("Bellek, 50.000 gönderi, pencere açık", "~110 MB"),
            ("Bellek, bir günlük kullanımdan sonra, ekran görsellerle dolu", "~280 MB"),
            ("Kütüphaneyi açma", "5 ms"),
            ("En yeni gönderilerin ilk sayfası", "0,6 ms"),
            ("50.000 gönderide kelime ya da öbek araması", "7–21 ms"),
            ("Süzgeçler (<code>platform:x has:video tag:…</code>, <code>from:@…</code>, klasörler)", "3–32 ms"),
            ("İndirme / kurulu uygulama", "15 MB / 29 MB"),
        ],
        "fine": "M4 Pro'lu Mac, macOS 27.2, wroopmark 1.7. Bellek sistemin “footprint” değeri; işlemci bir dakika boyunca <code>top</code> ile. Büyük bir içe aktarmadan sonra kütüphane bir kez arka planda dizinlenir (yazı tanıma, anlamına göre arama); bitene kadar işlemci kullanır. Süreler deponun kendi testinden: <code>WM_PERF_N=50000 cargo test --release --test perf -- --ignored</code>; kendin de çalıştırabilirsin.",
        "ipad_eyebrow": "iPad", "ipad_h2": "iPad'de üç sütun.", "ipad_text": "Kapsamlar, liste ve gönderi yan yana; aynı okuyucu, akış ve Ayıkla ile.",
        "ipad_alt": "iPad'de üç sütunlu wroopmark",
        "more_eyebrow": "Gerisi", "more_h2": "Geçip gitmek için değil, saklamak için.",
        "cards": [
            ("Kaydettiklerini izle", "Videolarını ve gönderilerini tam ekran, art arda; resim içinde resim, AirPlay ve oynatma hızıyla."),
            ("Hepsini getir", "TikTok, Instagram, X, Threads ve Reddit veri paketleri, tarayıcı yer imleri, Pocket ve Raindrop CSV."),
            ("Tarayıcı eklentisi", "Chrome, Brave, Arc, Edge, Vivaldi ve Safari: gezindikçe yer imlerin ve kaydedilenlerin arşive akar."),
            ("Düzenli tut", "Yeni kayıtları dosyalayan kurallar, kopyalar, kırık link taramalı link havuzu."),
            ("Yanında götür", "Markdown (Obsidian'a hazır, görselleriyle), CSV, JSON ya da herkese gönderebileceğin tek bir HTML sayfası."),
            ("Yapay zekâ ajanları için", "Yerel bir MCP sunucusu, Claude gibi ajanların arşivinde senin bilgisayarında arayıp okumasını sağlar."),
        ],
        "cmp_eyebrow": "Karşılaştırma", "cmp_h2": "Yalnızca linki değil, gönderinin kendisini saklar.",
        "cmp_head": ["", "wroopmark", "Sonra oku uygulamaları", "Yer imi yöneticileri", "Kendi sunucunda arşivleyiciler"],
        "cmp_rows": [
            ("Gönderinin görsel ve videolarını saklar", "✅", "—", "—", "bazıları"),
            ("Sosyal kaydedilenler (X, TikTok, Instagram, Reddit, Bluesky, Threads)", "✅", "—", "yalnızca link", "bazıları"),
            ("İnternetsiz, silinince de kalır", "✅", "makaleler", "—", "✅"),
            ("Görsellerde ve video konuşmasında arama", "✅", "—", "—", "—"),
            ("Cihazda yapay zekâ", "✅", "bulut", "bulut", "harici API"),
            ("Hesap yok, sunucu yok", "✅", "—", "—", "sunucu gerekir"),
            ("Yerel Mac, iPhone ve iPad uygulamaları", "✅", "✅", "✅", "web"),
        ],
        "get_eyebrow": "Edin", "get_h2": "Ücretsiz, gizli, senin.",
        "get": [
            ("Mac", "macOS 26 ve sonrası. Apple tarafından imzalı ve onaylı; kendini günceller, her güncellemenin imzasını önce doğrular.", "Mac için indir", DOWNLOAD),
            ("iPhone ve iPad", "Yakında App Store'da. İlk açılışta Paylaş menüsünü, Safari eklentisini ve iCloud yedeğini adım adım gösterir.", None, None),
            ("Açık kaynak", "MIT lisanslı. Kodu oku, kendin derle ya da bir fikir paylaş.", "GitHub'da kaynak", REPO),
        ],
        "footer": "© 2026 Furkan Türkoğlu · MIT Lisansı", "privacy": "Gizlilik", "support": "Destek",
        "credit": "Ekran görüntüleri demo kütüphanedeki Wikipedia makaleleridir (CC BY-SA 4.0).",
        "privacy_href": "privacy.html#tr", "support_href": "support.html#tr",
    },
}

# Mac tour: which screen each step shows and where the camera looks.
# (layer, zoom, origin x %, origin y %)
MAC_STEPS = [
    ("library", 1.0, 50, 50),
    ("library", 2.05, 98, 34),
    ("search", 1.45, 84, 0),
    ("today", 1.0, 50, 50),
    ("triage", 1.5, 45, 100),
    ("gallery", 1.0, 50, 50),
    ("reader", 1.22, 50, 45),
    ("library theme", 1.0, 50, 50),
]
MAC_LAYERS = [("library", "1-library"), ("search", "4-search"), ("today", "5-today"), ("triage", "2-triage"),
              ("gallery", "3-gallery"), ("reader", "6-reader")]
PHONE_STEPS = ["list sheet", "list island", "item", "reader", "triage"]
PHONE_LAYERS = [("list", "1-list"), ("item", "2-item"), ("reader", "3-reader"), ("triage", "4-triage")]


def esc(s):
    return html.escape(s, quote=True)


def steps_html(steps, prefix):
    out = []
    for i, (h, p) in enumerate(steps):
        out.append(f'''      <article class="step" data-i="{i}">
        <span class="n">{i + 1:02d}</span>
        <h3>{h}</h3>
        <p>{p}</p>
      </article>''')
    return "\n".join(out)


def dots(n):
    return '<div class="dots" aria-hidden="true">' + "".join(f'<i data-i="{i}"></i>' for i in range(n)) + "</div>"


def page(lang):
    t = T[lang]
    L = lang
    other = T[t["other"]]
    nav = "\n    ".join(f'<a href="{h}">{esc(n)}</a>' for h, n in t["nav"])
    ld = {
        "@context": "https://schema.org", "@type": "SoftwareApplication", "name": "wroopmark",
        "applicationCategory": "ProductivityApplication", "operatingSystem": "macOS 26, iOS 26, iPadOS 26",
        "inLanguage": lang, "description": t["desc"], "url": t["url"], "downloadUrl": DOWNLOAD,
        "softwareVersion": VERSION, "fileSize": "15MB",
        "offers": {"@type": "Offer", "price": "0", "priceCurrency": "USD"},
        "image": f"{SITE}images/{L}-mac-1-library.jpg",
        "screenshot": [f"{SITE}images/{L}-mac-1-library.jpg", f"{SITE}images/{L}-screen-1-list.jpg"],
        "license": "https://opensource.org/licenses/MIT",
        "author": {"@type": "Person", "name": "Furkan Türkoğlu"},
    }
    plat = "".join(f"<span>{esc(p)}</span>" for p in t["platforms"])
    stats = "\n".join(
        f'  <div class="stat reveal" style="--d:{i}"><b>{esc(pre or "")}<span data-count="{v}">{v}</span>{esc(unit)}</b><span>{esc(txt)}</span></div>'
        for i, (v, unit, txt, pre) in enumerate(t["stats"]))

    mac_layers = "\n".join(
        f'            <img class="layer" data-layer="{k}" src="images/{L}-mac-{f}.jpg" width="1600" height="867" alt="" {"" if k == "library" else "loading=\"lazy\" "}decoding="async">'
        for k, f in MAC_LAYERS)
    mac_steps = "\n".join(
        f'      <article class="step" data-i="{i}" data-show="{MAC_STEPS[i][0]}" data-zoom="{MAC_STEPS[i][1]}" data-ox="{MAC_STEPS[i][2]}%" data-oy="{MAC_STEPS[i][3]}%">\n'
        f'        <span class="n">{i + 1:02d}</span>\n        <h3>{h}</h3>\n        <p>{p}</p>\n      </article>'
        for i, (h, p) in enumerate(t["mac_steps"]))
    phone_layers = "\n".join(
        f'              <img class="layer" data-layer="{k}" src="images/{L}-screen-{f}.jpg" width="460" height="1000" alt="" loading="lazy" decoding="async">'
        for k, f in PHONE_LAYERS)
    phone_steps = "\n".join(
        f'      <article class="step" data-i="{i}" data-show="{PHONE_STEPS[i]}">\n'
        f'        <span class="n">{i + 1:02d}</span>\n        <h3>{h}</h3>\n        <p>{p}</p>\n      </article>'
        for i, (h, p) in enumerate(t["phone_steps"]))
    apps = "".join(
        (f'<div class="app hot"><img src="logo.png" alt=""><span>{esc(a)}</span></div>' if j == 0
         else f'<div class="app"><i class="ic{j}"></i><span>{esc(a)}</span></div>')
        for j, a in enumerate(t["share_apps"]))
    acts = "".join(f"<div>{esc(a)}</div>" for a in t["share_acts"])
    tokens = "".join(
        f'<span class="tok{" meaning" if i == len(t["search_tokens"]) - 1 else ""}" data-i="{i}">{esc(tok)}</span>'
        for i, tok in enumerate(t["search_tokens"]))
    search_steps = steps_html(t["search_steps"], "s")
    sync_steps = steps_html(t["sync_steps"], "y")
    sl = t["sync_labels"]
    words = " ".join(f"<span>{esc(w)}</span>" for w in t["private_text"].split(" "))
    table = "\n".join(f'        <tr><td>{a}</td><td class="n">{esc(b)}</td></tr>' for a, b in t["table"])
    cards = "\n".join(f'      <div class="card reveal" style="--d:{i}"><h3>{esc(h)}</h3><p>{esc(p)}</p></div>'
                      for i, (h, p) in enumerate(t["cards"]))
    cmp_head = "".join(f"<th>{esc(h)}</th>" for h in t["cmp_head"])
    cmp_rows = "\n".join("      <tr>" + "".join(f"<td>{esc(c)}</td>" for c in r) + "</tr>" for r in t["cmp_rows"])
    get = "\n".join(
        f'      <div class="card reveal" style="--d:{i}"><h3>{esc(h)}</h3><p>{esc(p)}</p>'
        + (f'<a class="btn" href="{u}">{esc(b)}</a>' if b else "") + "</div>"
        for i, (h, p, b, u) in enumerate(t["get"]))

    return f'''<!doctype html>
<html lang="{lang}">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{esc(t["title"])}</title>
<meta name="description" content="{esc(t["desc"])}">
<link rel="canonical" href="{t["url"]}">
<link rel="alternate" hreflang="en" href="{SITE}">
<link rel="alternate" hreflang="tr" href="{SITE}tr.html">
<link rel="icon" href="logo.png">
<link rel="stylesheet" href="site.css">
<script>document.documentElement.classList.add("js")</script>
<script src="site.js" defer></script>
<meta name="theme-color" content="#784AED">
<meta property="og:type" content="website">
<meta property="og:site_name" content="wroopmark">
<meta property="og:title" content="{esc(t["og_title"])}">
<meta property="og:description" content="{esc(t["og_desc"])}">
<meta property="og:url" content="{t["url"]}">
{'<meta property="og:locale" content="tr_TR">' if lang == "tr" else '<meta property="og:locale" content="en_US">'}
<meta property="og:image" content="{SITE}images/social-preview.png">
<meta property="og:image:width" content="1280">
<meta property="og:image:height" content="640">
<meta name="twitter:card" content="summary_large_image">
<meta name="twitter:title" content="{esc(t["og_title"])}">
<meta name="twitter:description" content="{esc(t["og_desc"])}">
<meta name="twitter:image" content="{SITE}images/social-preview.png">
<script type="application/ld+json">
{json.dumps(ld, ensure_ascii=False, indent=2)}
</script>
</head>
<body>
<div class="progress" aria-hidden="true"></div>
<div class="bar"><div class="bar-in">
  <a class="brand" href="{"./" if lang == "en" else "tr.html"}"><img src="logo.png" alt="">wroopmark</a>
  <nav>
    {nav}
    <a href="{other["file"] if t["other"] == "tr" else "./"}" hreflang="{t["other"]}">{esc(t["other_name"])}</a>
  </nav>
  <a class="btn small" href="{DOWNLOAD}">{esc(t["download"])}</a>
</div></div>

<header class="hero">
  <div class="orb a" data-speed="-140"></div>
  <div class="orb b" data-speed="-70"></div>
  <div class="orb c" data-speed="-220"></div>
  <div class="hero-copy">
    <h1>{esc(t["h1"])}</h1>
    <p class="lead">{esc(t["lead"])}</p>
    <div class="cta">
      <a class="btn" href="{DOWNLOAD}">{esc(t["download_mac"])}</a>
      <a class="btn ghost" href="#iphone">{esc(t["see_iphone"])}</a>
    </div>
    <p class="cta-note">{esc(t["cta_note"])}</p>
  </div>
  <div class="stage">
    <img class="mac" src="images/{L}-mac-1-library.jpg" width="1600" height="867" alt="{esc(t["hero_mac_alt"])}">
    <div class="iphone phone"><div class="screen"><img src="images/{L}-screen-1-list.jpg" width="460" height="1000" alt="{esc(t["hero_phone_alt"])}"></div></div>
  </div>
  <p class="hint" aria-hidden="true">{esc(t["scroll_hint"])}<i></i></p>
</header>

<section class="marquee" aria-label="{esc(t["saves_from"])}">
  <p class="eyebrow">{esc(t["saves_from"])}</p>
  <div class="track" data-marquee><div>{plat}</div><div aria-hidden="true">{plat}</div><div aria-hidden="true">{plat}</div></div>
</section>

<div class="stats">
{stats}
</div>

<main>
  <section class="intro-block">
    <p class="intro big reveal">{t["intro"]}</p>
  </section>

  <section class="chapter" id="mac">
    <div class="chapter-head">
      <p class="eyebrow reveal">{esc(t["mac_eyebrow"])}</p>
      <h2 class="reveal">{esc(t["mac_h2"])}</h2>
      <p class="intro reveal">{esc(t["mac_intro"])}</p>
    </div>
    <div class="tour mac-tour" data-tour>
      <div class="stage-col"><div class="sticky">
        <div class="device mac-device">
          <div class="zoomer">
{mac_layers}
          </div>
          <img class="float" data-layer="theme" src="images/{L}-mac-7-theme.png" width="1200" height="910" alt="" loading="lazy" decoding="async">
        </div>
        {dots(len(MAC_STEPS))}
      </div></div>
      <div class="steps">
{mac_steps}
      </div>
    </div>
  </section>

  <section class="chapter" id="iphone">
    <div class="chapter-head">
      <p class="eyebrow reveal">{esc(t["phone_eyebrow"])}</p>
      <h2 class="reveal">{esc(t["phone_h2"])}</h2>
      <p class="intro reveal">{esc(t["phone_intro"])}</p>
    </div>
    <div class="tour phone-tour" data-tour>
      <div class="stage-col"><div class="sticky">
        <div class="device iphone">
          <div class="screen">
            <img class="base" src="images/{L}-screen-1-list.jpg" width="460" height="1000" alt="" loading="lazy" decoding="async">
{phone_layers}
            <div class="island" data-layer="island"><img src="logo.png" alt=""><span>{esc(t["island"])}</span><b>✓</b></div>
            <div class="sheet" data-layer="sheet">
              <div class="grab"></div>
              <div class="sheet-head"><div class="thumb"></div><div><b>{esc(t["share_title"])}</b><span>{esc(t["share_url"])}</span></div></div>
              <div class="apps">{apps}</div>
              <div class="acts">{acts}</div>
            </div>
          </div>
        </div>
        {dots(len(PHONE_STEPS))}
      </div></div>
      <div class="steps">
{phone_steps}
      </div>
    </div>
  </section>

  <section class="chapter" id="search">
    <div class="chapter-head">
      <p class="eyebrow reveal">{esc(t["search_eyebrow"])}</p>
      <h2 class="reveal">{esc(t["search_h2"])}</h2>
    </div>
    <div class="tour search-tour" data-tour>
      <div class="stage-col"><div class="sticky">
        <div class="device searchbox">
          <div class="field"><i class="glass"></i><div class="toks">{tokens}<span class="caret"></span></div><span class="ph">{esc(t["search_ph"])}</span></div>
          <div class="chips" aria-hidden="true">{tokens}</div>
        </div>
        {dots(len(t["search_steps"]))}
      </div></div>
      <div class="steps">
{search_steps}
      </div>
    </div>
  </section>

  <section class="chapter" id="sync">
    <div class="chapter-head">
      <p class="eyebrow reveal">{esc(t["sync_eyebrow"])}</p>
      <h2 class="reveal">{esc(t["sync_h2"])}</h2>
    </div>
    <div class="tour sync-tour" data-tour>
      <div class="stage-col"><div class="sticky">
        <div class="device syncmap">
          <svg viewBox="0 0 800 440" role="img" aria-label="{esc(sl["mac"])} → {esc(sl["folder"])} → {esc(sl["phone"])}">
            <path class="wire w1" d="M262 220 C 310 220, 320 220, 352 220" pathLength="1"/>
            <path class="wire w2" d="M448 220 C 490 220, 500 220, 548 220" pathLength="1"/>
            <path class="wire w3" d="M448 236 C 540 300, 610 330, 668 330" pathLength="1"/>
            <g class="mac-ic"><rect x="40" y="140" width="220" height="140" rx="12"/><rect class="scr" x="52" y="152" width="196" height="116" rx="5"/><path d="M20 292 h260 l-14 14 h-232 z"/><text x="150" y="340">{esc(sl["mac"])}</text></g>
            <g class="folder"><circle class="halo" cx="400" cy="220" r="78"/><path class="fold" d="M352 188 h34 l10 12 h52 a8 8 0 0 1 8 8 v52 a8 8 0 0 1 -8 8 h-96 a8 8 0 0 1 -8 -8 v-64 a8 8 0 0 1 8 -8 z"/><text x="400" y="330">{esc(sl["folder"])}</text></g>
            <g class="phone-ic"><rect x="550" y="120" width="96" height="196" rx="18"/><rect class="scr" x="557" y="127" width="82" height="182" rx="12"/><rect class="isl" x="584" y="133" width="28" height="8" rx="4"/><text x="598" y="350">{esc(sl["phone"])}</text></g>
            <g class="phone2-ic"><rect x="670" y="250" width="70" height="140" rx="14"/><rect class="scr" x="675" y="255" width="60" height="130" rx="9"/><text x="705" y="414">{esc(sl["phone2"])}</text></g>
            <g class="chip log"><rect x="196" y="76" width="210" height="34" rx="17"/><text x="301" y="98">{esc(sl["log"])}</text></g>
            <g class="chip media"><rect x="470" y="76" width="110" height="34" rx="17"/><text x="525" y="98">{esc(sl["media"])}</text></g>
            <circle class="dot d1" r="6" cx="262" cy="220"/><circle class="dot d2" r="6" cx="448" cy="220"/>
          </svg>
        </div>
        {dots(len(t["sync_steps"]))}
      </div></div>
      <div class="steps">
{sync_steps}
      </div>
    </div>
  </section>

  <section class="private" id="private" data-words>
    <div class="private-in">
      <p class="eyebrow">{esc(t["private_eyebrow"])}</p>
      <p class="words">{words}</p>
      <a class="more" href="{t["privacy_href"]}">{esc(t["private_link"])} →</a>
    </div>
  </section>

  <section id="light">
    <div class="light reveal">
      <div class="orb" data-speed="-90"></div>
      <p class="eyebrow">{esc(t["light_eyebrow"])}</p>
      <h2>{esc(t["light_h2"])}</h2>
      <p class="intro">{esc(t["light_intro"])}</p>
      <figure class="cpu" data-draw>
        <figcaption><span>{esc(t["cpu_label"])}</span><b>{esc(t["cpu_value"])}</b></figcaption>
        <svg viewBox="0 0 600 120" preserveAspectRatio="none" aria-hidden="true">
          <path class="grid" d="M0 20 H600 M0 60 H600 M0 100 H600"/>
          <path class="line" d="M0 112 H600" pathLength="1"/>
        </svg>
      </figure>
      <div class="table-wrap">
      <table>
        <tr><th>{esc(t["table_head"][0])}</th><th>{esc(t["table_head"][1])}</th></tr>
{table}
      </table>
      </div>
      <p class="fine">{t["fine"]}</p>
    </div>
  </section>

  <section class="ipad">
    <div class="split">
      <div class="text">
        <p class="eyebrow reveal">{esc(t["ipad_eyebrow"])}</p>
        <h2 class="reveal">{esc(t["ipad_h2"])}</h2>
        <p class="intro reveal">{esc(t["ipad_text"])}</p>
      </div>
      <div class="ipad-frame reveal-fade" data-speed="-60"><img src="images/{L}-ipad-1.jpg" width="1600" height="1200" alt="{esc(t["ipad_alt"])}" loading="lazy" decoding="async"></div>
    </div>
  </section>

  <section>
    <p class="eyebrow reveal">{esc(t["more_eyebrow"])}</p>
    <h2 class="reveal">{esc(t["more_h2"])}</h2>
    <div class="grid">
{cards}
    </div>
  </section>

  <section>
    <p class="eyebrow reveal">{esc(t["cmp_eyebrow"])}</p>
    <h2 class="reveal">{esc(t["cmp_h2"])}</h2>
    <div class="table-wrap reveal">
    <table class="compare">
      <tr>{cmp_head}</tr>
{cmp_rows}
    </table>
    </div>
  </section>

  <section id="get">
    <p class="eyebrow reveal">{esc(t["get_eyebrow"])}</p>
    <h2 class="reveal">{esc(t["get_h2"])}</h2>
    <div class="get">
{get}
    </div>
  </section>
</main>

<footer>
  {esc(t["footer"])} · <a href="{t["privacy_href"]}">{esc(t["privacy"])}</a> · <a href="{t["support_href"]}">{esc(t["support"])}</a> · <a href="{t["other_href"]}" hreflang="{t["other"]}">{esc(t["other_name"])}</a><br>
  {esc(t["credit"])}
</footer>
</body>
</html>
'''


if __name__ == "__main__":
    for lang in ("en", "tr"):
        out = DOCS / T[lang]["file"]
        out.write_text(page(lang), encoding="utf-8")
        print("wrote", out.relative_to(DOCS.parent))
