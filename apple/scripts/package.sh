#!/usr/bin/env bash
# Builds the app and packs it for download: dist/wroopmark-<version>-macos-<arch>.zip
# and .dmg (drag to Applications). Used by the release workflow; works locally too.
#
#   apple/scripts/package.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
"$ROOT/apple/scripts/build-mac.sh"

APP="$ROOT/apple/build/wroopmark.app"
VERSION="$(grep -m1 '^version' "$ROOT/core/Cargo.toml" | cut -d'"' -f2)"
NAME="wroopmark-${VERSION}-macos-$(uname -m)"
DIST="$ROOT/dist"
mkdir -p "$DIST"
rm -f "$DIST/$NAME.zip" "$DIST/$NAME.dmg"

echo "==> $NAME.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$DIST/$NAME.zip"

echo "==> $NAME.dmg"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/İLK AÇILIŞ.txt" <<'TXT'
wroopmark'ı Applications klasörüne sürükle.

Uygulama Apple'a kayıtlı bir sertifikayla imzalı değil. İlk açılışta macOS
engellerse: Sistem Ayarları → Gizlilik ve Güvenlik → "Yine de aç".
Ya da Terminal'de bir kez:

  xattr -dr com.apple.quarantine /Applications/wroopmark.app

Sonra wroopmark → Ayarlar → Eklenti'den tarayıcı eklentisini kur.
TXT
hdiutil create -quiet -volname "wroopmark" -srcfolder "$STAGE" -fs HFS+ -format UDZO "$DIST/$NAME.dmg"

ls -lh "$DIST/$NAME".* | awk '{ print "==> " $5 "  " $9 }'
