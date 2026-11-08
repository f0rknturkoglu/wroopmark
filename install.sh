#!/usr/bin/env bash
# wroopmark: one command from a fresh checkout to a working app.
#
#   ./install.sh                  build from source and install (asks before installing tools)
#   ./install.sh --yes            same, answering yes to every question
#   ./install.sh --uninstall      remove the app (the library stays)
#
# What it does: checks macOS, installs what is missing (Xcode Command Line
# Tools, Rust), builds the app, puts it in /Applications, adds the
# `wroopmark` command, optionally installs the TikTok video tools, opens the
# app and walks through loading the browser extension.
set -euo pipefail
cd "$(dirname "$0")"

APP=/Applications/wroopmark.app
LIB="$HOME/Library/Application Support/wroopmark"
EXT_DIR="$LIB/chromium-extension"
YES=0
[[ "${1:-}" == "--yes" || "${1:-}" == "-y" ]] && YES=1

bold=$'\e[1m'; dim=$'\e[2m'; violet=$'\e[35m'; red=$'\e[31m'; green=$'\e[32m'; off=$'\e[0m'
step() { printf "\n%s==>%s %s%s%s\n" "$violet" "$off" "$bold" "$*" "$off"; }
note() { printf "    %s%s%s\n" "$dim" "$*" "$off"; }
fail() { printf "\n%shata:%s %s\n" "$red" "$off" "$*" >&2; exit 1; }
ask() {
  [[ $YES == 1 ]] && return 0
  [[ -t 0 ]] || return 1
  local a
  read -r -p "    $1 [E/h] " a
  [[ -z "$a" || "$a" =~ ^[EeYy] ]]
}

quit_app() {
  if pgrep -f "$APP/Contents/MacOS/wroopmark" >/dev/null; then
    note "açık olan wroopmark kapatılıyor"
    osascript -e 'tell application id "com.f0rknturkoglu.wroopmark" to quit' >/dev/null 2>&1 || true
    for _ in {1..20}; do pgrep -f "$APP/Contents/MacOS/wroopmark" >/dev/null || break; sleep 0.5; done
  fi
}

# --- Uninstall ----------------------------------------------------------------

if [[ "${1:-}" == "--uninstall" ]]; then
  step "wroopmark kaldırılıyor"
  quit_app
  pluginkit -r "$APP/Contents/PlugIns/WroopmarkSafari.appex" 2>/dev/null || true
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$APP" 2>/dev/null || true
  rm -rf "$APP"
  for dir in "$HOME/Library/Application Support"/{Google/Chrome,"Google/Chrome Beta","Google/Chrome Canary",Chromium,BraveSoftware/Brave-Browser,"Microsoft Edge",Vivaldi,"Arc/User Data",net.imput.helium}/NativeMessagingHosts; do
    rm -f "$dir/com.wroopmark.host.json"
  done
  for link in /usr/local/bin/wroopmark "$HOME/.local/bin/wroopmark"; do
    [[ -L "$link" ]] && rm -f "$link"
  done
  rm -rf "$EXT_DIR"
  printf "\n%s✓%s Uygulama kaldırıldı. Kütüphanen yerinde duruyor:\n    %s\n" "$green" "$off" "$LIB"
  note "Tarayıcıdaki eklentiyi de oradan kaldır."
  exit 0
fi

# --- Requirements --------------------------------------------------------------

step "Sistem"
[[ "$(uname)" == "Darwin" ]] || fail "wroopmark yalnızca macOS'ta çalışır."
major="$(sw_vers -productVersion | cut -d. -f1)"
(( major >= 14 )) || fail "macOS 14 (Sonoma) ya da daha yenisi gerekiyor; bu Mac'te $(sw_vers -productVersion)."
note "macOS $(sw_vers -productVersion), $(uname -m)"

if ! xcode-select -p >/dev/null 2>&1; then
  step "Xcode Command Line Tools"
  note "Swift derleyicisi için gerekiyor. Açılan pencerede \"Yükle\"ye bas,"
  note "kurulum bitince bu betiği yeniden çalıştır."
  xcode-select --install || true
  exit 1
fi

if ! command -v cargo >/dev/null 2>&1 && [[ -f "$HOME/.cargo/env" ]]; then
  # shellcheck disable=SC1091
  source "$HOME/.cargo/env"
fi
if ! command -v cargo >/dev/null 2>&1; then
  step "Rust"
  note "Çekirdek Rust ile yazılı; derlemek için rustup (resmî kurucu) gerekiyor."
  ask "Rust kurulsun mu (rustup.rs, ~1 dk)?" || fail "Rust olmadan derlenemez: https://rustup.rs"
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal
  # shellcheck disable=SC1091
  source "$HOME/.cargo/env"
fi
note "$(cargo --version)"

# --- Build & install -------------------------------------------------------------

step "Derleniyor (ilk seferde birkaç dakika sürer)"
quit_app
apple/scripts/build-mac.sh --install

# --- Command line ----------------------------------------------------------------

step "Terminal komutu"
CLI="$APP/Contents/Helpers/wroopmark"
linked=""
for dir in /usr/local/bin "$HOME/.local/bin"; do
  if [[ -d "$dir" && -w "$dir" ]]; then
    ln -sf "$CLI" "$dir/wroopmark"
    linked="$dir/wroopmark"
    break
  fi
done
if [[ -n "$linked" ]]; then
  note "wroopmark → $linked   (ör. wroopmark search \"tag:dev rust\")"
  [[ ":$PATH:" == *":$(dirname "$linked"):"* ]] || note "not: $(dirname "$linked") PATH'te değil"
else
  note "atlandı (/usr/local/bin yazılamıyor): ln -sf \"$CLI\" ~/bin/wroopmark"
fi

# --- TikTok video tools (optional) ------------------------------------------------

step "TikTok videoları için araçlar (isteğe bağlı)"
if command -v yt-dlp >/dev/null 2>&1 || [[ -x "$HOME/.local/bin/yt-dlp" ]]; then
  note "yt-dlp zaten kurulu"
elif ask "yt-dlp + gallery-dl kurulsun mu? (TikTok videolarını arka planda indirir)"; then
  if command -v uv >/dev/null 2>&1; then
    uv tool install "yt-dlp[default,curl-cffi]" && uv tool install gallery-dl
  elif command -v pipx >/dev/null 2>&1; then
    pipx install "yt-dlp[default,curl-cffi]" && pipx install gallery-dl
  elif command -v brew >/dev/null 2>&1; then
    brew install uv && uv tool install "yt-dlp[default,curl-cffi]" && uv tool install gallery-dl
  else
    note "uv, pipx ya da Homebrew bulunamadı. Sonra kurmak için:"
    note "  curl -LsSf https://astral.sh/uv/install.sh | sh"
    note "  uv tool install \"yt-dlp[default,curl-cffi]\" && uv tool install gallery-dl"
  fi
else
  note "atlandı; videolar yine tarayıcı eklentisi üzerinden iner"
fi

# --- First launch & extension -------------------------------------------------------

step "Uygulama açılıyor"
open "$APP"
# The app registers the browser bridge and copies the extension on launch.
for _ in {1..20}; do [[ -f "$EXT_DIR/manifest.json" ]] && break; sleep 0.5; done

cat <<EOF

${green}✓ wroopmark kuruldu:${off} $APP
  Kütüphane: $LIB

${bold}Tarayıcı eklentisi${off} (bir kez):
  Chrome / Brave / Arc / Edge:
    1. wroopmark → Ayarlar → Eklenti → tarayıcının düğmesi
       (eklentiler sayfası ve klasör açılır, yol panoya kopyalanır)
    2. Geliştirici modu → "Paketlenmemiş öğe yükle" → $EXT_DIR
  Safari:
    Ayarlar → Eklenti → "Safari'de aç" (imzasız kurulumda önce
    Safari → Ayarlar → Geliştirici → "İmzasız eklentilere izin ver")

${bold}Güncellemek için:${off} git pull && ./install.sh   (sonra eklentide ↻)
EOF
