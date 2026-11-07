#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
app=$1
version=$(cat VERSION)
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
contents="$app/Contents"
mkdir -p "$contents/MacOS" "$contents/Resources"
MACOSX_DEPLOYMENT_TARGET=12.0 /usr/bin/xcrun swiftc -O VFLR.swift -o "$contents/MacOS/TVT"
cp engine.sh update.sh UserGuide.txt VFLR.icns TVT.png ConversionProfiles.tsv subtitle_tools.py restore.sh disc_tools.py "$contents/Resources/"
cat > "$contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>TVT</string>
<key>CFBundleIdentifier</key><string>com.tedinvr.vflr</string>
<key>CFBundleName</key><string>Ted's Video Tool</string>
<key>CFBundleDisplayName</key><string>Ted's Video Tool</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleIconFile</key><string>VFLR.icns</string>
<key>CFBundleShortVersionString</key><string>$version</string>
<key>CFBundleVersion</key><string>$version</string>
<key>LSMinimumSystemVersion</key><string>12.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>CFBundleDocumentTypes</key><array><dict>
<key>CFBundleTypeName</key><string>Video</string>
<key>CFBundleTypeRole</key><string>Viewer</string>
<key>LSHandlerRank</key><string>Alternate</string>
<key>LSItemContentTypes</key><array><string>public.movie</string></array>
</dict></array>
</dict></plist>
PLIST
/usr/bin/plutil -lint "$contents/Info.plist" >&2
/usr/bin/codesign --force --sign - "$app"
/usr/bin/codesign --verify --strict "$app"
