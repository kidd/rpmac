#!/usr/bin/env bash
set -euo pipefail

VERSION="${1:?Usage: ./scripts/release.sh <version> (e.g. 0.2.0)}"
TAG="v${VERSION}"
APP_BUNDLE="rpmac.app"
ZIP_NAME="rpmac-${VERSION}-arm64.zip"

# Ensure clean working tree
if ! git diff --quiet HEAD; then
    echo "Error: working tree is dirty. Commit or stash changes first."
    exit 1
fi

# Build release binary
echo "Building release..."
swift build -c release

# Copy binary into .app bundle
cp .build/release/rpmac "${APP_BUNDLE}/Contents/MacOS/rpmac"

# Update version in Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${VERSION}" "${APP_BUNDLE}/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" "${APP_BUNDLE}/Contents/Info.plist"

# Ad-hoc sign (required on Apple Silicon)
codesign --force --sign - "${APP_BUNDLE}"

# Package
echo "Packaging ${ZIP_NAME}..."
zip -r "${ZIP_NAME}" "${APP_BUNDLE}"

# Tag and release
echo "Creating GitHub release ${TAG}..."
git tag "${TAG}"
git push origin "${TAG}"
gh release create "${TAG}" "${ZIP_NAME}" \
    --title "rpmac ${VERSION}" \
    --notes "rpmac ${VERSION} (arm64)"

# Clean up
rm "${ZIP_NAME}"

echo "Done: https://github.com/kidd/rpmac/releases/tag/${TAG}"
