#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <version> [release-notes]" >&2
  echo "Example: $0 1.1.0 \"新增扫描加速与应用内更新\"" >&2
  exit 1
fi

VERSION="$1"
NOTES="${2:-}"

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Error: Version must match X.Y.Z (e.g. 1.1.0), got '$VERSION'" >&2
  exit 1
fi

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

if ! command -v gh >/dev/null 2>&1; then
  echo "Error: gh CLI not found. Install GitHub CLI first." >&2
  exit 1
fi

if ! gh auth status >/dev/null 2>&1; then
  echo "Error: gh CLI is not authenticated. Run 'gh auth login' first." >&2
  exit 1
fi

TAG="v${VERSION}"
if git rev-parse "$TAG" >/dev/null 2>&1; then
  echo "Error: Git tag '$TAG' already exists." >&2
  exit 1
fi

printf '%s\n' "$VERSION" > "$ROOT_DIR/VERSION"

echo "==> Running unit tests..."
swift test --disable-sandbox --disable-xctest --enable-swift-testing

if [[ "${ALLOW_ADHOC:-0}" == "1" ]]; then
  REQUIRE_FIXED_SIGNING=0 "$ROOT_DIR/scripts/build-app.sh"
else
  REQUIRE_FIXED_SIGNING=1 "$ROOT_DIR/scripts/build-app.sh"
fi

DIST_DIR="$ROOT_DIR/dist"
ZIP_NAME="DiskGuard-${TAG}.zip"
ZIP_PATH="$DIST_DIR/$ZIP_NAME"
SHA_PATH="${ZIP_PATH}.sha256"

rm -f "$ZIP_PATH" "$SHA_PATH"
echo "==> Packaging $ZIP_NAME..."
ditto -c -k --sequesterRsrc --keepParent "$DIST_DIR/DiskGuard.app" "$ZIP_PATH"
(cd "$DIST_DIR" && shasum -a 256 "$ZIP_NAME" > "${ZIP_NAME}.sha256")

if ! git diff --quiet -- "$ROOT_DIR/VERSION"; then
  git add "$ROOT_DIR/VERSION"
  git commit -m "chore(release): bump version to ${VERSION}"
fi

git tag -a "$TAG" -m "DiskGuard ${TAG}"
echo "==> Pushing main and tag $TAG..."
git push origin main --follow-tags

echo "==> Creating GitHub Release $TAG..."
if [[ -n "$NOTES" ]]; then
  gh release create "$TAG" "$ZIP_PATH" "$SHA_PATH" \
    --title "DiskGuard ${TAG}" \
    --notes "$NOTES"
else
  gh release create "$TAG" "$ZIP_PATH" "$SHA_PATH" \
    --title "DiskGuard ${TAG}" \
    --generate-notes
fi

echo "==> Release $TAG published successfully."
