#!/usr/bin/env bash
# Builds the `wroopmark` binary, copies it next to the library and registers
# it as the native-messaging host for every Chromium browser found.
#
#   extensions/chromium/install-host.sh            # install
#   extensions/chromium/install-host.sh --remove   # unregister
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HOST_NAME="com.wroopmark.host"
# Fixed by the "key" in manifest.json.
EXT_ID="kdkgliladllpidmnacdcackcamaknlej"
LIB="${WROOPMARK_HOME:-$HOME/Library/Application Support/wroopmark}"
BIN="$LIB/bin/wroopmark"
SUPPORT="$HOME/Library/Application Support"
BROWSERS=(
  "Google/Chrome" "Google/Chrome Beta" "Google/Chrome Canary" "Chromium"
  "BraveSoftware/Brave-Browser" "Microsoft Edge" "Vivaldi" "Arc/User Data" "net.imput.helium"
)

if [[ "${1:-}" == "--remove" ]]; then
  for b in "${BROWSERS[@]}"; do
    rm -f "$SUPPORT/$b/NativeMessagingHosts/$HOST_NAME.json"
  done
  echo "==> kayıtlar silindi (kütüphaneye dokunulmadı: $LIB)"
  exit 0
fi

echo "==> wroopmark (release)"
(cd "$ROOT/core" && cargo build --release --bin wroopmark)
mkdir -p "$LIB/bin"
cp "$ROOT/core/target/release/wroopmark" "$BIN"
codesign --force --sign - "$BIN" >/dev/null 2>&1 || true

found=0
for b in "${BROWSERS[@]}"; do
  [[ -d "$SUPPORT/$b" ]] || continue
  dir="$SUPPORT/$b/NativeMessagingHosts"
  mkdir -p "$dir"
  cat > "$dir/$HOST_NAME.json" <<JSON
{
  "name": "$HOST_NAME",
  "description": "wroopmark",
  "path": "$BIN",
  "type": "stdio",
  "allowed_origins": ["chrome-extension://$EXT_ID/"]
}
JSON
  echo "==> $b"
  found=1
done
[[ $found == 1 ]] || echo "uyarı: Chromium tabanlı tarayıcı bulunamadı"

cat <<EOF

Eklentiyi yükle:
  1. chrome://extensions → Geliştirici modu
  2. "Paketlenmemiş öğe yükle" → $ROOT/extensions/chromium
  (kimlik $EXT_ID olmalı)

Terminalden de kullanmak için:  ln -sf "$BIN" /usr/local/bin/wroopmark
EOF
