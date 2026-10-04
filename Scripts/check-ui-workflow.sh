#!/bin/zsh
set -euo pipefail
setopt extendedglob
cd "${0:A:h:h}"
swift build
check_root="$PWD/.build/workflow-check"
check_app="$check_root/WorkflowCheck.app"
mkdir -p "$check_app/Contents/MacOS" "$check_app/Contents/Frameworks" "$check_app/Contents/Resources"
cp LICENSE "$check_app/Contents/Resources/LICENSE.txt"
swiftc -I .build/debug .build/debug/SwitchViewerInterpolation.o .build/debug/SwitchViewerGamePlugins.o .build/debug/SwitchViewerRecording.o \
    Sources/SwitchViewer/*.swift~Sources/SwitchViewer/main.swift \
    Scripts/check-ui-workflow.swift -o "$check_app/Contents/MacOS/WorkflowCheck"
cp .build/debug/GameHookFixture .build/debug/libSwitchViewerGameHook.dylib "$check_app/Contents/Frameworks/"
cat > "$check_app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>WorkflowCheck</string>
<key>CFBundleIdentifier</key><string>com.zhu.switchviewer.workflowcheck</string>
<key>CFBundleName</key><string>WorkflowCheck</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign --force --deep --sign - "$check_app"
"$check_app/Contents/MacOS/WorkflowCheck" "$@"
