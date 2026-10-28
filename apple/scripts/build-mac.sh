#!/usr/bin/env bash
# Build wroopmark.app: Rust core (static lib + native-host helper) + SwiftUI
# shell, packaged and ad-hoc signed into apple/build/wroopmark.app.
#
#   apple/scripts/build-mac.sh            # release build
#   apple/scripts/build-mac.sh --install  # also copy to /Applications
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CORE="$ROOT/core"
APP_PKG="$ROOT/apple"
OUT="$APP_PKG/build"
APP="$OUT/wroopmark.app"
export MACOSX_DEPLOYMENT_TARGET=14.0

echo "==> Rust core (release, LTO)"
(cd "$CORE" && cargo build --release)

# Newer SDKs implement SwiftUI's @State as a macro whose plugin ships with
# Xcode only. With just the Command Line Tools, pick the newest SDK that
# predates that change (same trick as forkjob).
if ! xcodebuild -version >/dev/null 2>&1; then
  for sdk in $(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX[0-9]*.sdk 2>/dev/null | sort -rV); do
    iface="$sdk/System/Library/Frameworks/SwiftUICore.framework/Modules/SwiftUICore.swiftmodule/arm64e-apple-macos.swiftinterface"
    if [ -f "$iface" ] && ! grep -q "StateMacro" "$iface"; then
      export SDKROOT="$sdk"
      echo "==> Xcode yok; SDK: $(basename "$sdk")"
      break
    fi
  done
fi

echo "==> SwiftUI app"
(cd "$APP_PKG" && swift build -c release -Xlinker -L"$CORE/target/release" -Xlinker -dead_strip)
BIN="$(cd "$APP_PKG" && swift build -c release --show-bin-path)/Wroopmark"

echo "==> Bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/wroopmark"
strip -x "$APP/Contents/MacOS/wroopmark" 2>/dev/null || true
# The browser extension's native-messaging host (and a CLI).
cp "$CORE/target/release/wroopmark" "$APP/Contents/Helpers/wroopmark"
if [ -f "$APP_PKG/Resources/AppIcon.icns" ]; then
  cp "$APP_PKG/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi
VERSION="$(grep -m1 '^version' "$CORE/Cargo.toml" | cut -d'"' -f2)"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>wroopmark</string>
  <key>CFBundleDisplayName</key><string>wroopmark</string>
  <key>CFBundleDevelopmentRegion</key><string>tr</string>
  <key>CFBundleIdentifier</key><string>com.f0rknturkoglu.wroopmark</string>
  <key>CFBundleExecutable</key><string>wroopmark</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>MIT — Furkan Türkoğlu</string>
</dict>
</plist>
PLIST

echo "==> OCR helper"
# Vision in a short-lived process: the app stays light after a scan.
xcrun swiftc -O -target "$(uname -m)-apple-macos${MACOSX_DEPLOYMENT_TARGET}" \
  "$APP_PKG/OCR/main.swift" -o "$APP/Contents/Helpers/wroopmark-ocr"
strip -x "$APP/Contents/Helpers/wroopmark-ocr" 2>/dev/null || true

echo "==> Safari extension"
# A Safari web extension is an app extension inside the app: the shared
# extension JS as resources plus a native handler that links the core.
EXT_SRC="$ROOT/extensions/chromium"
APPEX="$APP/Contents/PlugIns/WroopmarkSafari.appex"
mkdir -p "$APPEX/Contents/MacOS" "$APPEX/Contents/Resources"
xcrun swiftc -O -application-extension -module-name WroopmarkSafari \
  -target "$(uname -m)-apple-macos${MACOSX_DEPLOYMENT_TARGET}" \
  -I "$APP_PKG/Sources/CWroopmark" -L "$CORE/target/release" \
  -framework SafariServices -framework Security -framework SystemConfiguration \
  -Xlinker -e -Xlinker _NSExtensionMain -Xlinker -dead_strip \
  "$APP_PKG/Safari/SafariWebExtensionHandler.swift" -o "$APPEX/Contents/MacOS/WroopmarkSafari"
strip -x "$APPEX/Contents/MacOS/WroopmarkSafari" 2>/dev/null || true
cp -R "$EXT_SRC"/*.js "$EXT_SRC"/*.html "$EXT_SRC/icons" "$APPEX/Contents/Resources/"
# Safari's manifest: no Chromium-only keys, and hook.js is injected by
# relay.js (web_accessible_resources) instead of a MAIN-world content script.
python3 - "$EXT_SRC/manifest.json" "$APPEX/Contents/Resources/manifest.json" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
for k in ("key", "minimum_chrome_version"):
    m.pop(k, None)
sites = m["content_scripts"][0]["matches"]
m["content_scripts"] = [c for c in m["content_scripts"] if c.get("world") != "MAIN"]
m["web_accessible_resources"] = [{"resources": ["hook.js"], "matches": sites}]
json.dump(m, open(sys.argv[2], "w"), ensure_ascii=False, indent=2)
PY
cat > "$APPEX/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>WroopmarkSafari</string>
  <key>CFBundleDisplayName</key><string>wroopmark</string>
  <key>CFBundleDevelopmentRegion</key><string>tr</string>
  <key>CFBundleIdentifier</key><string>com.f0rknturkoglu.wroopmark.safari</string>
  <key>CFBundleExecutable</key><string>WroopmarkSafari</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundlePackageType</key><string>XPC!</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHumanReadableDescription</key><string>X yer imlerini, TikTok favorilerini ve sayfaları wroopmark arşivine kaydeder.</string>
  <key>NSExtension</key>
  <dict>
    <key>NSExtensionPointIdentifier</key><string>com.apple.Safari.web-extension</string>
    <key>NSExtensionPrincipalClass</key><string>SafariWebExtensionHandler</string>
  </dict>
</dict>
</plist>
PLIST

# An "Apple Development" certificate (Xcode → Settings → Accounts → Manage
# Certificates) lets Safari load the extension without "Allow unsigned
# extensions"; without one everything is signed ad hoc.
SIGN_ID="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/ { print $2; exit }')"
SIGN_ID="${SIGN_ID:--}"
echo "==> imza: $([ "$SIGN_ID" = "-" ] && echo "ad-hoc" || echo "$SIGN_ID")"

# Inside out: helper and extension first, then the app around them.
codesign --force --sign "$SIGN_ID" "$APP/Contents/Helpers/wroopmark" >/dev/null 2>&1
codesign --force --sign "$SIGN_ID" "$APP/Contents/Helpers/wroopmark-ocr" >/dev/null 2>&1
codesign --force --sign "$SIGN_ID" --entitlements "$APP_PKG/Safari/WroopmarkSafari.entitlements" "$APPEX" >/dev/null 2>&1
codesign --force --sign "$SIGN_ID" "$APP" >/dev/null 2>&1
codesign --verify --deep --strict "$APP"
echo "==> $(du -sh "$APP" | cut -f1)  $APP"

# Rebuilding deletes the old bundle, and with it Safari's registration of
# the extension; register the copy that will be used, and only that one
# (two extensions with the same id confuse Safari).
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
register() {
  "$LSREGISTER" -f "$1"
  pluginkit -a "$1/Contents/PlugIns/WroopmarkSafari.appex"
}

if [[ "${1:-}" == "--install" ]]; then
  pluginkit -r "$APPEX" 2>/dev/null || true
  "$LSREGISTER" -u "$APP" 2>/dev/null || true
  rm -rf "/Applications/wroopmark.app"
  cp -R "$APP" /Applications/
  register "/Applications/wroopmark.app"
  echo "==> /Applications/wroopmark.app (bir kez aç: Chromium eklentisi de oraya bağlanır)"
elif [[ ! -d "/Applications/wroopmark.app" ]]; then
  register "$APP"
fi
