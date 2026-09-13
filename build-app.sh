#!/bin/bash
# Assembles AppMover.app from the SPM executable.
# ponytail: a shell script, not an Xcode project. Nothing here needs a project file.
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-release}"
APP="AppMover.app"
BUNDLE_ID="com.gauravkumar.appmover"
# The update check compares this against the newest GitHub release tag, so it must come from
# the tag, not a hand-edited string. Untagged builds are 0.0.0: every release is newer.
VERSION="$(git describe --tags --abbrev=0 2>/dev/null || echo v0.0.0)"
VERSION="${VERSION#v}"
BUILD="$(git rev-list --count HEAD)"

# The compiler lists every localizable string it sees. Kept under .build, not a temp dir: an
# incremental build only re-emits the files it recompiled, and syncing a partial list would
# mark every other string stale.
STRINGS=".build/strings-$CONFIG"
mkdir -p "$STRINGS"
swift build -c "$CONFIG" --product AppMover \
    -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc "$STRINGS"
BIN="$(swift build -c "$CONFIG" --product AppMover --show-bin-path)/AppMover"
# What Xcode does on every build: new strings land in the catalog untranslated, and strings
# no longer in the code are marked stale. Open Resources/Localizable.xcstrings in Xcode to
# translate.
xcrun xcstringstool sync Resources/Localizable.xcstrings --stringsdata "$STRINGS"/*.stringsdata
# xcstringstool compiles a translation with the wrong placeholders without a word; the first
# anyone hears of it is garbage, or a crash, in that one language. Fail the build instead.
python3 - Resources/Localizable.xcstrings <<'PY'
import json, re, sys
def specs(s):
    found = re.findall(r'%(?:(\d+)\$)?(l{0,2}[@diuxXofeEgG])', s.replace('%%', ''))
    return sorted((int(n) if n else i + 1, kind) for i, (n, kind) in enumerate(found))
bad = []
for key, entry in json.load(open(sys.argv[1]))['strings'].items():
    for lang, loc in entry.get('localizations', {}).items():
        units = ([loc['stringUnit']] if 'stringUnit' in loc
                 else [form['stringUnit'] for form in loc['variations']['plural'].values()])
        bad += [f"{lang}: {u['value']!r}" for u in units if specs(u['value']) != specs(key)]
sys.exit("Placeholders differ from the English key:\n" + "\n".join(bad) if bad else 0)
PY

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/AppMover"
# Before codesign: a resource added after signing invalidates the signature.
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# <lang>.lproj straight into the app bundle, where SwiftUI and String(localized:) look by
# default -- not an SPM resource bundle, which neither would ever search.
xcrun xcstringstool compile Resources/Localizable.xcstrings --output-directory "$APP/Contents/Resources"

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
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD</string>
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
