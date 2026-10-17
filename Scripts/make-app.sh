#!/usr/bin/env bash
#
# Assemble Nymbra.app: a real bundle, so the application can be launched from
# Finder, kept in the Dock, dragged to /Applications and handed to someone else.
#
# Nothing here is signed or notarised — that needs a Developer ID and belongs to
# M6 proper. An unsigned bundle runs happily when it was built locally; what it
# cannot do is survive a download from the internet without Gatekeeper's
# quarantine prompt.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Nymbra.app"
CONTENTS="$APP/Contents"
IDENTIFIER="io.nymbra.terminal"
VERSION="0.1.0"
MINIMUM_MACOS="12.0"

# The build number is the commit count: it only ever goes up, and there is no
# second file to keep in step with the version.
BUILD_NUMBER="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 0)"

echo "app: building the release binary"
swift build -c release --package-path "$ROOT" >/dev/null

echo "app: assembling $APP"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"

cp "$ROOT/.build/release/Nymbra" "$CONTENTS/MacOS/Nymbra"
chmod +x "$CONTENTS/MacOS/Nymbra"

# The icon is drawn rather than stored as a binary: reviewable, reproducible, and
# derived from the same colours the terminal draws with. See Scripts/make-icon.swift.
echo "app: drawing the icon"
swift "$ROOT/Scripts/make-icon.swift" "$CONTENTS/Resources/AppIcon.icns" >/dev/null

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key><string>en</string>
	<key>CFBundleExecutable</key><string>Nymbra</string>
	<key>CFBundleIdentifier</key><string>${IDENTIFIER}</string>
	<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
	<key>CFBundleName</key><string>Nymbra</string>
	<key>CFBundleDisplayName</key><string>Nymbra</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>${VERSION}</string>
	<key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
	<key>CFBundleIconFile</key><string>AppIcon</string>
	<key>LSMinimumSystemVersion</key><string>${MINIMUM_MACOS}</string>
	<key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
	<key>NSHighResolutionCapable</key><true/>
	<key>NSPrincipalClass</key><string>NSApplication</string>
	<key>NSHumanReadableCopyright</key><string>MIT licensed.</string>
</dict>
</plist>
PLIST

printf 'APPL????' > "$CONTENTS/PkgInfo"

# A malformed plist makes a bundle silently unlaunchable, so lint it: the check
# costs a fraction of a second and the failure it prevents is bewildering.
plutil -lint "$CONTENTS/Info.plist" >/dev/null

# Nudge Finder and the Dock to pick up the icon rather than a stale cache.
touch "$APP"

echo "app: $APP"
echo "app: version ${VERSION} (${BUILD_NUMBER}), $(du -sh "$APP" | cut -f1)"
