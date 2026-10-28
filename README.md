# wroopmark

Sosyal medya kayıtlarını (X yer imleri, TikTok kaydedilen ve beğenilenleri,
herhangi bir web sayfası) tek bir çerçevede, **çevrimdışı** saklayan,
aranabilir ve etiketlenebilir yerel arşiv. Docker, sunucu ya da arka plan
servisi yok. Rust çekirdeği, SwiftUI macOS uygulaması, Safari ve Chromium
eklentilerinden oluşur.

- Metin, görseller, videolar ve linkler diske iner; kaynak silinse de kayıt kalır.
- Tek arama kutusu: `rust tag:dev -from:@jack has:image after:2024 "tam ifade"`.
  Türkçe katlama yapılır: "istanbul" ⇔ "İSTANBUL" ⇔ "ıstanbul".
- Gelişmiş filtre paneli (platform, medya, link/not/OCR/alıntı, etiket, kişi,
  tarih aralığı) ve sıralama (tarih, kişi, karışık).
- Kart, liste ve akış (gönderiler tam boy, kaydırarak okunur) görünümleri.
- Ayıkla: kayıtlar tek tek gelir, ← sil, → sakla, ⌘Z geri al.
- Hiyerarşik etiketler (`dev/rust`), not, link havuzu, foto/video galerisi.
- İsteğe bağlı OCR (Apple Vision, cihazda): ekran görüntüsündeki yazı da aranır.
- Aynı medya bir kez indirilir (içerik adresli depo + URL eşlemesi).

Ayrıntılar için [ARCHITECTURE.md](ARCHITECTURE.md).

## Kurulum (macOS 14+)

Gerekenler: Rust (stable), Xcode Command Line Tools.

```bash
apple/scripts/build-mac.sh --install
```

Uygulama `/Applications/wroopmark.app` olarak kurulur. Kütüphane
`~/Library/Application Support/wroopmark/` altındadır.

İmza: "Apple Development" sertifikası varsa onunla, yoksa ad-hoc imzalanır.
Ad-hoc imzada Safari eklentisi için Safari → Ayarlar → Geliştirici →
"İmzasız eklentilere izin ver" gerekir (Safari her açılışta sıfırlar).

### TikTok videoları (isteğe bağlı)

TikTok video dosyalarını yalnızca tarayıcı gibi davranan istemcilere veriyor.
yt-dlp (`curl_cffi` ile) kuruluysa eksik videolar arka planda iner; gallery-dl
ikinci, tarayıcı eklentisi son yedek:

```bash
uv tool install "yt-dlp[default,curl-cffi]"
uv tool install gallery-dl
```

### Eklentiler

- **Safari**: uygulamanın içinde gelir; Safari → Ayarlar → Uzantılar'dan açılır.
- **Chromium** (Chrome, Brave, Arc, Edge…): `chrome://extensions` → Geliştirici
  modu → "Paketlenmemiş öğe yükle" → `extensions/chromium`. Uygulama ilk açılışta
  native messaging host'unu kaydeder.

Eklenti açıkken X'te yer imleri sayfasını ya da TikTok profilindeki
Favoriler/Beğenilenler sekmesini kaydırmak yeterli; popup'taki düğmeler bunu
otomatik yapar.

## Geliştirme

```bash
cd core && cargo test && cargo clippy --all-targets && cargo fmt --check
```

CLI aynı çekirdeği kullanır (`WROOPMARK_HOME` ile başka bir kütüphane seçilir):

```bash
core/target/release/wroopmark search "tag:dev rust"
```

| Yol | Ne |
|---|---|
| `core/` | Rust çekirdek: SQLite + FTS5, ayrıştırıcılar, medya deposu, JSON API, CLI / native host |
| `apple/` | SwiftUI macOS uygulaması, OCR yardımcısı, Safari eklentisinin native tarafı |
| `extensions/chromium/` | MV3 eklenti (Safari sürümü de buradan üretilir) |

## Lisans

[MIT](LICENSE)
