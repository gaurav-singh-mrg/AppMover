#!/bin/bash
# Assembles AppMover.app from the SPM executable.
# ponytail: a shell script, not an Xcode project. Nothing here needs a project file.
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-release}"
APP="AppMover.app"
BUNDLE_ID="com.gauravkumar.appmover"

swift build -c "$CONFIG" --product AppMover
BIN="$(swift build -c "$CONFIG" --product AppMover --show-bin-path)/AppMover"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/AppMover"
# Before codesign: a resource added after signing invalidates the signature.
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>AppMover</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleName</key><string>AppMover</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleDisplayName</key><string>AppMover</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>AppMover</string>
</dict>
</plist>
PLIST

# Ad-hoc signing is fine to launch, but Full Disk Access binds to the signing identity and
# an ad-hoc cdhash changes on every rebuild -- so the grant must be re-applied after each
# build. Swap in a Developer ID once you stop rebuilding constantly:
#   codesign --force --deep -s "Developer ID Application: ..." --options runtime "$APP"
codesign --force --deep -s - "$APP" 2>/dev/null

echo "built $APP"
