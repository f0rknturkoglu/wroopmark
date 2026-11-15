# wroopmark — mimari

Sosyal medya kayıtlarını (X, Facebook, TikTok, Pinterest, herhangi bir URL) tek
bir çerçevede, çevrimdışı saklayan; aranabilir, etiketlenebilir arşiv.
Hedef: Docker yok, sunucu yok, arka plan servisi yok, headless tarayıcı yok.

```
                ┌──────────────── giriş kanalları ────────────────┐
 Chromium ext ──┤ native messaging → wroopmark CLI (aynı binary)  │
 Safari ext   ──┤ SafariWebExtensionHandler (sandbox) → core (FFI) │
 macOS app    ──┤ URL yapıştır / sürükle-bırak                    │
 iOS app      ──┤ Kısayol (App Intent) + paylaşım menüsü          │
                └───────────────────────┬─────────────────────────┘
                                        ▼
                        wroopmark_core (Rust, staticlib + CLI)
                 extractors · SQLite + FTS5 · medya deposu · sync log
                                        ▼
                ~/Library/Application Support/wroopmark/
                   library.sqlite      (cihaza özel, senkronlanmaz)
                   media/ab/<xxh3>.jpg (içerik adresli, çakışmasız)
```

## Klasörler

| Yol | Ne |
|---|---|
| `core/` | Rust çekirdek. `staticlib` → Swift uygulamasına linklenir, `wroopmark` CLI → test + Chromium native host |
| `extensions/chromium/` | MV3 eklenti (Chrome, Brave, Arc, Edge, Helium…); uygulamanın içine de kopyalanır, uygulama açılışta `~/Library/Application Support/wroopmark/chromium-extension`'a yazar (tarayıcı buradan yükler) |
| `apple/Safari/` | Safari eklentisinin native handler'ı ve yetkileri; JS `extensions/chromium/`'dan kopyalanır |
| `apple/` | SwiftUI macOS uygulaması (iOS sonra), forkjob'daki FFI kalıbıyla; `apple/OCR/` ayrı OCR yardımcısı |

## Çerçeve (ortak şema)

Her kayıt bir `Item`: `id, platform, url, author_handle, author_name, title,
text, created_at, saved_at, media[], links[], quote?, tags[], note, raw`.

- **Deterministik id**: `x:<tweet id>`, `tiktok:<video id>`, `pinterest:<pin id>`,
  `web:<url hash>`. Aynı gönderi iki cihazda kaydedilse de aynı id'yi alır →
  senkronda tekilleştirme bedava.
- **`raw`** (zstd'li orijinal JSON) saklanır: şema değişince ağa çıkmadan yeniden
  ayrıştırılabilir; platform içeriği silse de elimizde kalır.
- **Link havuzu**: her kayıttaki URL'ler normalize edilir (`utm_*`, `fbclid`, `si`
  gibi izleyiciler atılır, `twitter.com → x.com`), tekilleştirilir, hangi
  kayıtlarda geçtiği tutulur. Başlık/görsel tembel çekilir (`enrich_links`).

## Arama

- SQLite FTS5 (`unicode61`), Tantivy/Meilisearch yok.
- Metin indekslenmeden **ve** sorgu çalışmadan önce Rust'ta katlanır:
  `İ I ı → i`, aksanlar atılır (`ş→s, ğ→g, ö→o…`). "istanbul" ⇔ "İSTANBUL" ⇔ "ıstanbul".
- Sözdizimi: `rust async tag:dev -tag:okundu from:@jack platform:x has:image
  before:2025-06 after:2024 "tam ifade" -kelime is:untagged is:tagged`,
  ayrıca `has:ocr` (görselde yazı), `has:quote`, `is:reviewed` (ayıklamada
  saklanan), `savedafter:` / `savedbefore:` (kaydedilme tarihi),
  `folder:ad` (alt klasörler dahil), `is:unfiled`, `id:x:123` (tam o kayıt).
  Her süzgeç başına `-` alarak tersine döner: `-from:@jack`, `-@jack`,
  `-platform:tiktok`, `-has:video`, `-is:untagged`.
- Sıralama sorgudan ayrı bir parametre (`sort`): önerilen (metin varsa
  alaka), kaydedilme / paylaşılma tarihi (iki yön), kişi, karışık (tohumlu,
  sayfalar arasında tutarlı).
- Uygulamadaki gelişmiş filtre paneli yalnızca bu terimleri üretir; panelde
  yapılan her şey arama kutusuna yazılarak da yapılabilir.
- Etiketler hiyerarşik: `tag:dev` → `dev`, `dev/rust`, `dev/swift`.
- Global arama aynı anda kayıtları ve link havuzunu döndürür. Sorguda kayıt
  süzgeci (etiket, kişi, platform, tarih…) varsa yalnızca bu süzgece uyan
  kayıtlarda geçen linkler gelir.
- Apple Vision OCR (isteğe bağlı, ayarlardan) görsellerdeki yazıyı `ocr`
  alanına yazar → ekran görüntüsü tweet'ler de aranabilir.
- `site:github.com`: gönderinin kendi adresi ya da içindeki bir link o sitede.
- **Kurallar** (`rules` tablosu): kayıtlı bir arama + etiket ve/veya klasör. Yeni
  oluşan her kayıt (`save_into`) ve dolan her stub kurallardan geçer; sorgu motoru
  aynısı (`Query` + `id:` kısıtı). Klasör yalnızca klasörsüz kayda konur.

## Sayfa kopyaları (v0.4)

Web sayfası kayıtları (`web`, `github`, `arxiv`, `hackernews`) uygulamada görünmez bir
`WKWebView`'da (çerezsiz, kalıcı veri yok) açılır, kaydırılıp tembel görseller
yüklendikten sonra `createWebArchiveData` ile `.webarchive` olur; medya deposunda
`items.snapshot`. WebKit'in okuduğu metin (betikler çalışmış hâli) mevcut makale
metninden uzunsa `extra`'ya yazılır. Tek tek, iki saniye arayla; başaramayan 3 kez
denenir, 40 MB üstü saklanmaz. Görüntüleyici betikleri kapalı açar: arşivdeki sayfa
siteye istek atmaz.

## Kısayollar (App Intents)

`apple/Sources/Wroopmark/AppIntents.swift`. SwiftPM `Metadata.appintents` üretmez;
`build-mac.sh` derleyicinin `.swiftconstvalues` dosyalarından
`appintentsmetadataprocessor` ile üretip `Contents/Resources`'a koyar (Xcode gerekir).

## Cihazdaki zeka (v0.3)

Modeller sistemin kendisi: NaturalLanguage `NLContextualEmbedding` (Latin alfabesi,
512 boyut) ve Foundation Models (Apple Intelligence). İkisi de `wroopmark-ai`
yardımcısında çalışır (`apple/AI/main.swift`, JSON satırları stdin/stdout); çekirdek
onu gerektiğinde başlatır, bir dakika boşta kalınca kendisi kapanır. Uygulama ve
çekirdek model belleği tutmaz; CLI ve MCP de aynı yolu kullanır.

- **Vektörler**: kayıt başına int8 + ölçek (~0,5 KB, `vectors` tablosu). Metni çok
  kısa olan (25 harften az) kayıt vektör almaz: anlamsız kısa metinler her aramaya
  yakın çıkıyordu. Karşılaştırma kaba kuvvet; ortak yön (kütüphane ortalaması)
  çıkarılıp yeniden normalize edilir, yoksa ortalama alınmış vektörlerin hepsi
  birbirine 0,7+ benzer. Model değişirse dizin silinip yeniden oluşur.
- **Anlamsal arama** üç listenin RRF birleşimi: aramanın kendisi (FTS, ağırlık 1),
  dil modelinin önerdiği ilgili kelimelerle genişletilmiş VEYA araması (0,8;
  önbellekli) ve en yakın vektörler (0,5; merkezli kosinüs ≥ 0,42). Türkçe için
  Apple'ın cümle gömme modeli yok; genişletme bu açığı kapatıyor.
- **Özet ve etiket önerisi**: `summarize`, `items.summary` / `ai_tags`'e yazar,
  etiketleri kendisi eklemez. Ayıklama ekranı sıradaki kartları önceden özetler.
- **Benzerleri / kopyalar**: aynı merkezli vektörler; kopyalar ayrıca aynı medya
  dosyası ve katlanmış aynı metin.

## Senkron (v0.5)

Tasarım yukarıdaki "Senkron = klasör + işlem günlüğü". Uygulama (`api/sync.rs`,
`db/sync.rs`):

- **Değişiklik takibi tetikleyicilerle** (`sync_dirty`): uygulama, eklenti host'u ya da
  CLI, kim yazarsa yazsın kaçmaz. Alan grupları: `content` (metin, medya listesi,
  alıntı, zincir, OCR…), `tags`, `folder` (klasör yolu, adıyla), `note`, `reviewed`,
  `ai`; ayrıca silme ve `ui.` ayarları (kayıtlı aramalar). Uzak değişiklik uygulanırken
  (`sync_state.applying`) tetikleyiciler susar, yankı olmaz.
- **Gönderme**: değişen her kayıt için bir satır, yalnızca değişen gruplarla, kaydın
  o anki hâlinden. Görseller (seçime göre videolar da) içerik adıyla `media/`'ya.
- **Alma**: diğer cihazların dosyaları kaldığı yerden (`sync_cursor`, bayt konumu)
  okunur, yalnızca tam satırlar; zamana göre sıralanıp uygulanır. Grup başına son
  yazan kazanır (`sync_fields`: zaman ms + cihaz id). Silme, kaydın en yeni
  yazımından yeniyse uygulanır. Dosyası klasörde olan medya kopyalanır, olmayan her
  cihazda kendi iner.
- Aynı anda tek senkron (kütüphanedeki `sync.lock`). Boşta bir tur ~6 ms; 1766
  kayıtlık ilk tur: 3 MB günlük + 410 MB görsel.
- Vektörler, sayfa kopyaları ve video indirme denemeleri cihaza özel kalır.

## iOS (v0.5)

`apple/iOS/Wroopmark.xcodeproj` (Xcode 16+ eşzamanlı klasör grubu: `apple/iOS/Wroopmark/`
içindeki dosyalar kendiliğinden projede). Mac'le ortak: `Core.swift` (FFI köprüsü) ve
`Models.swift`; Rust çekirdeği aynısı, `scripts/build-ios-core.sh` derleme adımı
cihaz ya da simülatör için `cargo build --target aarch64-apple-ios[-sim]` çalıştırır.

- Kütüphane uygulamanın kendi kabında (`Application Support/wroopmark`).
- Senkron klasörü dosya seçiciden; erişim yer imi (bookmark) ile kalıcı. iCloud
  indirmediği dosyaları yer tutucu (`.ad.icloud`) bırakır: senkrondan önce günlük
  dosyaları `startDownloadingUbiquitousItem` + koordineli okumayla indirilir; görseller
  gerekmez (klasörde yoksa webden iner).
- Telefon sitelerden video indirmez (App Store kuralı 5.2.3); video ancak Mac'in
  senkron klasörüne koyduğu dosyadan oynar. OCR, vektörler ve sayfa kopyaları Mac'te
  üretilir, OCR ve özetler senkronla gelir.
- Mağaza hazırlığı: gizlilik manifestleri (`PrivacyInfo.xcprivacy`, uygulama ve
  eklentide; veri toplanmaz), `ITSAppUsesNonExemptEncryption = NO`, saydamlıksız
  1024 px ikon, medya klasörü iCloud yedeğinin dışında, ilk sürüm yalnızca iPhone.
  Gizlilik politikası: [PRIVACY.md](PRIVACY.md); uygulamada Ayarlar → Hakkında.
- Dayanıklılık: arka plana geçerken `pause` (indirmeler durur, WAL katlanır; ortak
  kaptaki SQLite kilitli kalıp iOS uygulamayı 0xdead10cc ile öldürmesin). Telefonda
  1 GB'tan az yer kalınca görsel indirme durur (`set_media_paused`) ve uyarı çıkar;
  bu, manifestteki disk alanı gerekçelerinin (E174.1, 85F4.1) karşılığı. İnternet
  yokken "+" ve Kısayollar bağlantıyı `save_link` ile saklar.
- Mağaza metni ve inceleme notları: `apple/iOS/AppStore.md`.
- Paylaşım eklentisi (`apple/iOS/ShareExtension`): uygulamayla aynı kütüphaneyi App
  Group kabında (`group.com.f0rknturkoglu.wroopmark`) kullanır; bağlantıyı ağa
  çıkmadan `save_link` ile stub olarak yazar, uygulama açılınca ayrıntıları getirir.
- App Intents: kaydet, ara, bul. `wroopmark://item/<id>`
  ve `wroopmark://search?q=` bağlantıları.

## Ajanlar (MCP)

`wroopmark mcp`: CLI ikilisinin stdio üzerinde JSON-RPC (MCP 2025-06-18) modu
(`mcp.rs`). Her araç `api.rs`'deki bir komuta denk gelir; `--read-only` yazanları
listeden çıkarır. Kayıtlar ayrıca `wroopmark://item/{id}` kaynak şablonuyla Markdown
olarak okunur (`resources/read`). Ajan bağlanınca açılır, boru kapanınca çıkar.

## Veri alma

| Kaynak | Yol |
|---|---|
| X yer imleri | Eklenti, x.com'un kendi GraphQL cevaplarını dinler. `/i/bookmarks` bir kez kaydırılınca tüm arşiv gelir. Yer imine eklediğin anda (`CreateBookmark`) o tweet daha önce görülen timeline cevabından alınıp kaydedilir. API ücreti yok, giriş bilgisi bizde değil. |
| Tek tweet URL'si | `publish.twitter.com/oembed` (metin + yazar, görselsiz) |
| TikTok | Eklenti: Kaydedilenler / Beğenilenler listeleri (sayfanın kendi API yanıtları); fotoğraf gönderilerinin tüm görselleri |
| Instagram | Eklenti: Kaydedilenler sayfasının kendi API yanıtları (REST ya da GraphQL); kaydet düğmesine basınca o gönderi |
| Reddit | Eklenti: `/user/<ad>/saved.json` kullanıcının kendi oturumuyla, 100'er 100'er (gönderi + yorum) |
| X zincirleri | Eklenti: tweet sayfasının `TweetDetail` cevabı çekirdeğe gider (`import_x_thread`); aynı yazarın birbirine yanıt veren tweet'leri (`in_reply_to_status_id`) bulunur, zincirin arşivdeki ilk kaydına `thread` olarak eklenir. Görselleri kaydın `media`'sına katılır (iner, kopya taramasına girer); yer imi listesi kaydı yeniden getirse de zincir korunur. |
| YouTube | Eklenti: yalnızca Daha Sonra İzle (`WL`) ve Beğenilenler (`LL`): sayfadaki `ytInitialData` + `youtubei/v1/browse` devamları, `playlistVideoRenderer`'lar sadeleştirilip kuyruğa (`youtube.rs`). Video inmez, kapak iner. |
| Bluesky | Eklenti: `app.bsky.bookmark.getBookmarks` ve `getActorLikes` cevaplarındaki `postView`'lar (`bluesky.rs`): görseller, video (HLS, yt-dlp ile), alıntı, linkler. Yanıt bağlamı (`reply.parent`) alınmaz. |
| Pinterest / Facebook / web | Sayfanın `og:` etiketleri + makale metni |
| Toplu | `bookmarks.html`, TikTok / Instagram / X veri paketleri (zip, klasör ya da tek dosya; zip sistemin `ditto`'suyla açılır), Pocket / Raindrop / Reddit CSV (`archive.rs`). Çoğu yalnızca link + tarih verir: kayıt doğru id'yle *stub* olarak girer (`items.stub = 1`), metin / yazar / medya arka planda `fetcher.capture` ile tek tek, acele etmeden gelir (en çok 3 deneme). Zaten olan kayda yalnızca etiket eklenir, içeriği ezilmez. İzleme / tarama geçmişi alınmaz. |
| Diskteki dosyalar | Video ve görseller medya deposuna kopyalanır (`localfile.rs`). Adında TikTok numarası (19 hane) ya da yt-dlp `[id]`'si olan video o gönderiye bağlanır: kayıt varsa videosu olur, yoksa stub açılır. Diğerleri `local:<içerik hash>` kayıt (aynı dosya iki kez girmez). Kapağı olmayan videolara uygulama AVFoundation ile kapak çizer (`posterless` / `set_poster`). |

Görseller, video kapakları ve (Ayarlar'dan kapatılabilir) videolar indirilir.
Video dosyası doğrudan bir mp4 değilse (TikTok gönderi sayfası) sırayla:

1. **yt-dlp** (`curl_cffi` ile; TikTok'un bot kontrolünü tarayıcı taklidiyle geçer),
   1080p'ye kadar HEVC tercih edilir (aynı çözünürlükte H.264'ün ~1/5'i, AVFoundation oynatır),
2. **gallery-dl**,
3. son çare **tarayıcı eklentisi**: gönderi tarayıcıda arka planda açılır, video
   sayfanın içinden kullanıcının oturumuyla alınır.

Araçlar uygulamayla gelmez; `$PATH`, `~/.local/bin` ve Homebrew klasörlerinde
aranır. Kuyruğu yalnızca uygulama işler (eklenti süreçleri program başlatamaz);
videolar birkaç saniye arayla tek tek iner, başaramayan 6 saat sonra yeniden
denenir (en çok 3 kez).

## macOS + iOS ve imzalama

Ücretsiz Apple ID ile imzalama (Xcode / AltStore / SideStore) varsayımıyla
tasarlandı; ücretli hesap gelirse sadece kolaylaşır.

- Ücretsiz hesapta **CloudKit / iCloud entitlement yok**, App Groups da büyük
  ihtimalle yok. Tasarım bunlara dayanmaz.
- **Senkron = klasör + işlem günlüğü**: kullanıcı bir klasör seçer (iOS'ta Files
  seçicisiyle iCloud Drive klasörü — entitlement gerektirmez; Mac'te herhangi bir
  klasör ya da Syncthing). Her cihaz kendi `ops/<cihaz>/<ay>.jsonl` dosyasına
  sadece ekleme yapar, diğerlerininkini okur; medya `media/` altında hash'le
  durur. SQLite dosyası asla senkron klasörüne konmaz (iki yazar = bozulma).
  Çakışma: alan bazında son-yazan-kazanır (zaman damgası + cihaz id).
- **iOS'ta hızlı kayıt**: Share Extension ana uygulamanın verisine App Group
  olmadan yazamaz. Bu yüzden asıl yol bir **App Intent** ("wroopmark'a kaydet"):
  ana uygulama sürecinde çalışır, Kısayollar'dan paylaşım menüsüne eklenir.
  Ayrıca uygulama açılınca panodaki linki önerir.
- **iOS Safari eklentisi**: aynı App Group sorunu; X arşivini Mac'teki eklenti
  alır, iPhone senkronla görür. App Group çalışırsa eklenir.
- Ücretsiz imza 7 günde bir yenilenir (AltStore/SideStore otomatik yeniler),
  en fazla 3 uygulama.

## Yol haritası

İlke: her özellik isteğe bağlı ve hafif kalır. Yeni sunucu, arka plan servisi,
indirilecek model ya da kalıcı RAM yükü yok; ne gerekiyorsa sistemde hazır olan
çerçevelerle (NaturalLanguage, Foundation Models, WebKit) ve SQLite'la yapılır.

**Yapıldı (v0.1)**
- Çekirdek: şema, FTS5 + Türkçe katlama, içerik adresli medya deposu, CLI
- X / TikTok / Instagram / Reddit yakalama, Chromium + Safari eklentisi
- SwiftUI uygulaması: galeri, ayıkla, link havuzu + kırık link taraması,
  kayıtlı aramalar, Spotlight, menü çubuğu + ⌃⌥⌘S, yedek, OCR

**v0.2: Bağlantılar** ✅
- MCP sunucusu (`wroopmark mcp`, stdio): ajanlar (Claude vb.) arşivde arar,
  kaydı okur, kaydeder, etiketler. Ayrı süreç; yalnızca ajan bağlıyken çalışır.
- Otomatik kurallar: site / platform / kişi / metin → etiket ya da klasör;
  kayıt anında, istenirse geriye dönük.
- Dışa aktarım: Markdown (Obsidian uyumlu, ön madde + medya), CSV; arama
  sonucundan ya da klasörden.
- İçe aktarım: tarayıcı `bookmarks.html`, platform veri paketleri (TikTok,
  Instagram, X beğenileri; çoğu yalnızca link verir, medya arka planda iner).
- Yerel dosya içe aktarımı: diskteki video ve görseller (ör. eskiden indirilmiş
  TikTok videoları). Dosya adında gönderi kimliği varsa o kayda bağlanır.

**v0.3: Akıllı arama** ✅ (cihazda, Apple Intelligence / NaturalLanguage varsa)
- Anlamsal arama: `NLContextualEmbedding` vektörleri SQLite'ta + dil modeliyle
  arama genişletme; FTS ile hibrit sıralama (RRF). Kayıt başına ~0,5 KB.
- Foundation Models ile özet ve etiket önerisi (ayıkla ekranında), "Benzerleri".
- Kopyalar: aynı link, aynı medya, neredeyse aynı metin.

**v0.4: Kalıcılık** ✅
- Web sayfasının tam kopyası: görünmez `WKWebView` → webarchive / PDF + okuma
  görünümü metni (Monolith gibi harici araç yok).
- X zincirleri: zincir açılınca aynı yazarın devam tweet'leri tek kayıtta.
- YouTube "Daha Sonra İzle" / oynatma listeleri, Bluesky.
- Ajanlar için: App Intents (Kısayollar, Siri ve Apple Intelligence'tan "wroopmark'ta
  ara / kaydet"; çalışırken yükü yok, Xcode derlemesi gerekir), MCP kaynakları
  (kayıtların `wroopmark://` adresleriyle doğrudan okunması).

**v0.5: Çoklu cihaz**
- Senkron günlüğü ✅ (aşağıda).
- iOS uygulaması + App Intent ✅ (aşağıda).

**Şimdilik yok**: metin vurgulama, EPUB, Raycast eklentisi (MCP çoğunu
karşılar), harici API anahtarıyla AI (cihazdaki model yetmezse).
