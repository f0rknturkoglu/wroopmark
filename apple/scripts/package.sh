#!/usr/bin/env bash
# Builds the app and packs it for download: dist/wroopmark-<version>-macos-<arch>.zip
# and .dmg (drag to Applications).
#
# With a "Developer ID Application" certificate and a notary profile named
# `wroopmark` (xcrun notarytool store-credentials wroopmark …) the app and the
# dmg are signed, notarized by Apple and stapled: they open without any
# warning, offline too. Without them the packages are ad hoc signed.
#
#   apple/scripts/package.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export WROOPMARK_RELEASE=1
"$ROOT/apple/scripts/build-mac.sh"

APP="$ROOT/apple/build/wroopmark.app"
VERSION="$(grep -m1 '^version' "$ROOT/core/Cargo.toml" | cut -d'"' -f2)"
NAME="wroopmark-${VERSION}-macos-$(uname -m)"
DIST="$ROOT/dist"
mkdir -p "$DIST"
rm -f "$DIST/$NAME.zip" "$DIST/$NAME.dmg"

# -dvv: since macOS 27 a single -v no longer prints the Authority lines.
# awk reads to the end: an early exit would SIGPIPE codesign under pipefail.
SIGNER="$(codesign -dvv "$APP" 2>&1 | awk -F= '/^Authority=/ && !s { print $2; s = 1 }')"
NOTARIZE=0
if [[ "$SIGNER" == "Developer ID Application:"* ]] && xcrun notarytool history --keychain-profile wroopmark >/dev/null 2>&1; then
  NOTARIZE=1
fi

notarize() {
  echo "==> Apple onayı: $(basename "$1") (birkaç dakika)"
  xcrun notarytool submit "$1" --keychain-profile wroopmark --wait | tail -3
}

if [ "$NOTARIZE" = 1 ]; then
  # The app itself first, so the ticket travels inside both packages.
  TMPZIP="$(mktemp -d)/app.zip"
  ditto -c -k --keepParent "$APP" "$TMPZIP"
  notarize "$TMPZIP"
  xcrun stapler staple "$APP" >/dev/null
  rm -f "$TMPZIP"
else
  echo "==> uyarı: Developer ID + notary profili yok; paket Apple onaysız (ilk açılışta uyarı çıkar)"
fi

echo "==> $NAME.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$DIST/$NAME.zip"

echo "==> $NAME.dmg"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
if [ "$NOTARIZE" = 0 ]; then
  cat > "$STAGE/İLK AÇILIŞ.txt" <<'TXT'
wroopmark'ı Applications klasörüne sürükle.

Bu paket Apple onaylı değil. İlk açılışta macOS engellerse:
Sistem Ayarları → Gizlilik ve Güvenlik → "Yine de aç".
Ya da Terminal'de bir kez:

  xattr -dr com.apple.quarantine /Applications/wroopmark.app

Sonra wroopmark → Ayarlar → Eklenti'den tarayıcı eklentisini kur.
TXT
fi
hdiutil create -quiet -volname "wroopmark" -srcfolder "$STAGE" -fs HFS+ -format UDZO "$DIST/$NAME.dmg"

if [ "$NOTARIZE" = 1 ]; then
  codesign --force --sign "$SIGNER" --timestamp "$DIST/$NAME.dmg"
  notarize "$DIST/$NAME.dmg"
  xcrun stapler staple "$DIST/$NAME.dmg" >/dev/null
  spctl --assess --type open --context context:primary-signature -v "$DIST/$NAME.dmg" 2>&1 | sed 's/^/==> /'
fi

ls -lh "$DIST/$NAME".* | awk '{ print "==> " $5 "  " $9 }'
