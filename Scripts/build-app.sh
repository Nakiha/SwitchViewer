#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
# Record the actual SDK version separately from the macOS 13 deployment target.
# SwiftPM's linker defaults can otherwise opt the app into older system visuals.
build_sdk_version="$(xcrun --sdk macosx --show-sdk-version)"
swift build -c release -Xlinker -platform_version -Xlinker macos -Xlinker 13.0 -Xlinker "$build_sdk_version"
mkdir -p SwitchViewer.app/Contents/MacOS SwitchViewer.app/Contents/Frameworks SwitchViewer.app/Contents/Resources
cp LICENSE SwitchViewer.app/Contents/Resources/LICENSE.txt
cp .build/release/SwitchViewer SwitchViewer.app/Contents/MacOS/SwitchViewer
cp .build/release/GameHookFixture SwitchViewer.app/Contents/Frameworks/GameHookFixture
cp .build/release/libSwitchViewerGameHook.dylib SwitchViewer.app/Contents/Frameworks/libSwitchViewerGameHook.dylib
if [[ ! -f SwitchViewer.app/Contents/Info.plist ]]; then
    cat > SwitchViewer.app/Contents/Info.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>SwitchViewer</string>
<key>CFBundleIdentifier</key><string>com.zhu.switchviewer</string>
<key>CFBundleName</key><string>SwitchViewer</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSCameraUsageDescription</key><string>SwitchViewer 需要访问采集卡画面。</string>
<key>NSMicrophoneUsageDescription</key><string>SwitchViewer 需要访问采集卡音频。</string>
</dict></plist>
PLIST
fi
# Always update existing bundles as well as fresh builds.
/usr/libexec/PlistBuddy -c 'Delete :LSUIElement' SwitchViewer.app/Contents/Info.plist 2>/dev/null || true
/usr/libexec/PlistBuddy -c 'Add :LSUIElement bool true' SwitchViewer.app/Contents/Info.plist
codesign --force --sign - SwitchViewer.app/Contents/Frameworks/GameHookFixture
codesign --force --sign - SwitchViewer.app/Contents/Frameworks/libSwitchViewerGameHook.dylib
codesign --force --sign - SwitchViewer.app
codesign --verify --strict SwitchViewer.app
