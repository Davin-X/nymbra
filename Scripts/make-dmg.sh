#!/bin/sh
# Build build/Nymbra.dmg: the app beside an Applications shortcut, so
# installing is a drag. Uses only hdiutil, which ships with macOS.
set -eu

cd "$(dirname "$0")/.."
[ -d build/Nymbra.app ] || { echo "dmg: build/Nymbra.app is missing; run make app first" >&2; exit 1; }

version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" build/Nymbra.app/Contents/Info.plist)

# A fixed staging folder inside build/, so cleaning it up can only ever
# touch that one folder.
rm -rf build/dmg-stage
mkdir build/dmg-stage
ditto --noextattr --norsrc build/Nymbra.app build/dmg-stage/Nymbra.app
ln -s /Applications build/dmg-stage/Applications

rm -f build/Nymbra.dmg
hdiutil create -quiet -volname "Nymbra $version" -srcfolder build/dmg-stage \
    -fs HFS+ -format UDZO -imagekey zlib-level=9 build/Nymbra.dmg
rm -rf build/dmg-stage
hdiutil verify -quiet build/Nymbra.dmg
echo "dmg: build/Nymbra.dmg ($(du -h build/Nymbra.dmg | cut -f1)), Nymbra $version"
