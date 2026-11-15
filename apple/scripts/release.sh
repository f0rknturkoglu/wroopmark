#!/usr/bin/env bash
# Publishes the Mac release from this Mac (the certificate and the notary
# profile live here, not on GitHub): tags v<version> if needed, pushes the
# tag, builds signed + notarized packages and puts them on the GitHub release.
#
#   apple/scripts/release.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
VERSION="$(grep -m1 '^version' core/Cargo.toml | cut -d'"' -f2)"
TAG="v$VERSION"

if [ -n "$(git status --porcelain)" ]; then
  echo "hata: commit'lenmemiş değişiklik var; önce commit et." >&2
  exit 1
fi
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null || git tag "$TAG"
git push origin "$TAG"

apple/scripts/package.sh
FILES=(dist/wroopmark-"$VERSION"-macos-*.dmg dist/wroopmark-"$VERSION"-macos-*.zip)
NOTES="Mac: .dmg'yi aç, wroopmark'ı Applications'a sürükle. Kaynaktan kurmak için: ./install.sh"
if gh release view "$TAG" >/dev/null 2>&1; then
  gh release upload "$TAG" "${FILES[@]}" --clobber
else
  gh release create "$TAG" "${FILES[@]}" --title "wroopmark $TAG" --notes "$NOTES"
fi
echo "==> $(gh release view "$TAG" --json url --jq .url)"
