#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
# Record the actual SDK version separately from the macOS 13 deployment target.
# SwiftPM's linker defaults can otherwise opt the app into older system visuals.
build_sdk_version="$(xcrun --sdk macosx --show-sdk-version)"
swift build -c release -Xlinker -platform_version -Xlinker macos -Xlinker 13.0 -Xlinker "$build_sdk_version"
# Assemble and sign fresh files; never overwrite a running executable in place.
stage_dir="$(mktemp -d "$PWD/.build/app-bundle.XXXXXX")"
trap 'rm -rf "$stage_dir"' EXIT
app_bundle="$stage_dir/SwitchViewer.app"
mkdir -p "$app_bundle/Contents/MacOS" "$app_bundle/Contents/Frameworks" "$app_bundle/Contents/Resources"
cp LICENSE "$app_bundle/Contents/Resources/LICENSE.txt"
cp .build/release/SwitchViewer "$app_bundle/Contents/MacOS/SwitchViewer"
cp .build/release/GameHookFixture "$app_bundle/Contents/Frameworks/GameHookFixture"
cp .build/release/libSwitchViewerGameHook.dylib "$app_bundle/Contents/Frameworks/libSwitchViewerGameHook.dylib"
python3 Scripts/write-app-metadata.py "$app_bundle"
codesign --force --sign - "$app_bundle/Contents/Frameworks/GameHookFixture"
codesign --force --sign - "$app_bundle/Contents/Frameworks/libSwitchViewerGameHook.dylib"
codesign --force --sign - "$app_bundle"
codesign --verify --strict "$app_bundle"
if [[ -e SwitchViewer.app ]]; then
    mv SwitchViewer.app "$stage_dir/previous.app"
fi
mv "$app_bundle" SwitchViewer.app
