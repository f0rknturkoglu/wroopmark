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
| `extensions/chromium/` | MV3 eklenti (Chrome, Brave, Arc, Edge, Helium…) |
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

## Veri alma

| Kaynak | Yol |
|---|---|
| X yer imleri | Eklenti, x.com'un kendi GraphQL cevaplarını dinler. `/i/bookmarks` bir kez kaydırılınca tüm arşiv gelir. Yer imine eklediğin anda (`CreateBookmark`) o tweet daha önce görülen timeline cevabından alınıp kaydedilir. API ücreti yok, giriş bilgisi bizde değil. |
| Tek tweet URL'si | `publish.twitter.com/oembed` (metin + yazar, görselsiz) |
| TikTok | Eklenti: Kaydedilenler / Beğenilenler listeleri (sayfanın kendi API yanıtları); fotoğraf gönderilerinin tüm görselleri |
| Instagram | Eklenti: Kaydedilenler sayfasının kendi API yanıtları (REST ya da GraphQL); kaydet düğmesine basınca o gönderi |
| Reddit | Eklenti: `/user/<ad>/saved.json` kullanıcının kendi oturumuyla, 100'er 100'er (gönderi + yorum) |
| Pinterest / Facebook / web | Sayfanın `og:` etiketleri + makale metni |
| Toplu | (sonra) TikTok "Favorite Videos" / Facebook "Saved items" export içe aktarma |

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

1. ✅ Çekirdek: şema, FTS, medya deposu, CLI
2. ✅ X içe aktarıcı + Chromium eklentisi (native messaging)
3. ✅ SwiftUI macOS uygulaması (`apple/scripts/build-mac.sh`; native host uygulamanın içinde, videolar dahil çevrimdışı medya; tarayıcıdan link sürükle-bırak)
4. ✅ Safari eklentisi (uygulamanın içinde `PlugIns/WroopmarkSafari.appex`; JS Chromium'la ortak, native taraf çekirdeğe doğrudan bağlı)
5. Senkron günlüğü
6. iOS uygulaması + App Intent (Xcode gerekir) — ertelendi
7. OCR ✅ · toplu export içe aktarma · otomatik etiket kuralları
