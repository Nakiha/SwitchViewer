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
python3 Scripts/write-app-metadata.py SwitchViewer.app
codesign --force --sign - SwitchViewer.app/Contents/Frameworks/GameHookFixture
codesign --force --sign - SwitchViewer.app/Contents/Frameworks/libSwitchViewerGameHook.dylib
codesign --force --sign - SwitchViewer.app
codesign --verify --strict SwitchViewer.app
