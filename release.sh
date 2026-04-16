#!/bin/bash
set -euo pipefail

if [ $# -ne 1 ]; then
  echo "Usage: $0 <version>   e.g. $0 1.0.0 or $0 v1.0.0"
  exit 1
fi

RAW_VERSION="$1"
VERSION="${RAW_VERSION#v}"
TAG="v$VERSION"

if ! command -v gh >/dev/null 2>&1; then
  echo "Error: gh CLI not found."
  echo "Install it with: brew install gh && gh auth login"
  exit 1
fi

if ! git diff-index --quiet HEAD --; then
  echo "Error: working tree is dirty. Commit or stash changes before releasing."
  exit 1
fi

if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
  echo "Error: tag $TAG already exists locally."
  exit 1
fi

if git ls-remote --exit-code --tags origin "$TAG" >/dev/null 2>&1; then
  echo "Error: tag $TAG already exists on origin."
  exit 1
fi

xcodebuild \
  -project UnnamedWindowManager.xcodeproj \
  -scheme UnnamedWindowManager \
  -configuration Release \
  build

BUILD_DIR=$(xcodebuild \
  -project UnnamedWindowManager.xcodeproj \
  -scheme UnnamedWindowManager \
  -configuration Release \
  -showBuildSettings 2>/dev/null \
  | grep -m 1 'BUILT_PRODUCTS_DIR' \
  | sed 's/.*= //')

APP_PATH="$BUILD_DIR/UnnamedWindowManager.app"
if [ ! -d "$APP_PATH" ]; then
  echo "Error: $APP_PATH not found"
  exit 1
fi

STAGING=$(mktemp -d)
trap 'rm -rf "$STAGING"' EXIT
ZIP_PATH="$STAGING/UnnamedWindowManager-$TAG.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"

git tag -a "$TAG" -m "Release $TAG"
git push origin "$TAG"

gh release create "$TAG" \
  "$ZIP_PATH" \
  --title "$TAG" \
  --generate-notes

echo "Released $TAG"
