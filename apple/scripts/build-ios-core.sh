#!/bin/sh
# Xcode build phase of the iOS app: builds the Rust core for the device or
# the simulator. Run from a clean environment: Xcode's (SDKROOT for iOS…)
# would make cargo build its macOS-side helpers against the iOS SDK.
set -e
case "$PLATFORM_NAME" in
  iphonesimulator) TARGET=aarch64-apple-ios-sim ;;
  *) TARGET=aarch64-apple-ios ;;
esac
CORE="$SRCROOT/../../core"
# rustup's own installer puts it in ~/.cargo/bin, Homebrew's rustup elsewhere.
TOOLS="$HOME/.cargo/bin:/opt/homebrew/opt/rustup/bin:/opt/homebrew/bin:/usr/local/bin"
CARGO="$(PATH="$TOOLS:$PATH" command -v cargo || true)"
if [ -z "$CARGO" ]; then
  echo "error: Rust yok. Kur: https://rustup.rs, sonra: rustup target add aarch64-apple-ios aarch64-apple-ios-sim"
  exit 1
fi
cd "$CORE"
env -i HOME="$HOME" PATH="$TOOLS:/usr/bin:/bin:/usr/sbin:/sbin" \
  IPHONEOS_DEPLOYMENT_TARGET=26.0 \
  "$CARGO" build --release --lib --target "$TARGET"
