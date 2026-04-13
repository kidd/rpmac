#!/bin/bash
set -e

echo "Building rpmac..."
swift build -c release

echo "Creating app bundle..."
mkdir -p rpmac.app/Contents/MacOS

cat > rpmac.app/Contents/Info.plist << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>rpmac</string>
    <key>CFBundleIdentifier</key>
    <string>com.rgrau.rpmac</string>
    <key>CFBundleName</key>
    <string>rpmac</string>
    <key>CFBundleVersion</key>
    <string>0.1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSBackgroundOnly</key>
    <true/>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
PLIST

echo "Copying binary to app bundle..."
cp .build/release/rpmac rpmac.app/Contents/MacOS/rpmac

# Re-sign so macOS recognizes it as a proper app
codesign --force --sign - rpmac.app

# Remove quarantine/provenance attributes so macOS doesn't re-prompt for authorization
xattr -cr rpmac.app

echo ""
echo "Done. Run with:"
echo "  open rpmac.app"
echo ""
echo "Or directly:"
echo "  rpmac.app/Contents/MacOS/rpmac"
echo ""
echo "To install to /Applications:"
echo "  cp -r rpmac.app /Applications/"
