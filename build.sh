#!/bin/bash
set -e

echo "Building rpmac..."
swift build -c release

echo "Copying binary to app bundle..."
cp .build/release/rpmac rpmac.app/Contents/MacOS/rpmac

# Re-sign so macOS recognizes it as a proper app
codesign --force --sign - rpmac.app

echo ""
echo "Done. Run with:"
echo "  open rpmac.app"
echo ""
echo "Or directly:"
echo "  rpmac.app/Contents/MacOS/rpmac"
echo ""
echo "To install to /Applications:"
echo "  cp -r rpmac.app /Applications/"
