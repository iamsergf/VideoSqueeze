#!/bin/zsh
set -e
cd "$(dirname "$0")"
APP=build/VideoSqueeze.app
rm -rf build && mkdir -p $APP/Contents/MacOS $APP/Contents/Resources build/AppIcon.iconset

# Universal binary: Apple Silicon + Intel
for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -target $arch-apple-macos14.0 \
    Sources/*.swift -o build/VideoSqueeze-$arch
done
lipo -create build/VideoSqueeze-arm64 build/VideoSqueeze-x86_64 -output $APP/Contents/MacOS/VideoSqueeze
rm build/VideoSqueeze-arm64 build/VideoSqueeze-x86_64

swift make_icon.swift build/AppIcon.iconset
iconutil -c icns build/AppIcon.iconset -o $APP/Contents/Resources/AppIcon.icns

cat > $APP/Contents/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>VideoSqueeze</string>
  <key>CFBundleDisplayName</key><string>VideoSqueeze</string>
  <key>CFBundleIdentifier</key><string>local.videosqueeze</string>
  <key>CFBundleExecutable</key><string>VideoSqueeze</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleDevelopmentRegion</key><string>ru</string>
</dict></plist>
PLIST

xattr -cr $APP
codesign --force --deep -s - $APP
# Zip for GitHub Releases
ditto -c -k --norsrc --noextattr --keepParent $APP build/VideoSqueeze.zip
echo "Built $APP and build/VideoSqueeze.zip"
