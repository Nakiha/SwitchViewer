#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
# Builds without signing for validation. Install via Xcode with your own Team.
platform="${1:-device}"
case "$platform" in
  device) destination='generic/platform=iOS' ;;
  simulator) destination='generic/platform=iOS Simulator' ;;
  *) print -u2 'Usage: Scripts/build-ipad-app.sh [device|simulator]'; exit 2 ;;
esac
xcodebuild -project iPad/SwitchViewerIPad.xcodeproj -scheme SwitchViewerIPad \
  -configuration Debug -destination "$destination" \
  -derivedDataPath ".build/ipad-$platform" CODE_SIGNING_ALLOWED=NO build
