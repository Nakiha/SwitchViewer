#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
Scripts/build-app.sh
release_version="$(python3 Scripts/write-app-metadata.py --version)"
release_arch="$(lipo -archs SwitchViewer.app/Contents/MacOS/SwitchViewer | tr ' ' '-')"
release_dir="$PWD/dist"
mkdir -p "$release_dir"
release_name="SwitchViewer-$release_version-macos-$release_arch.zip"
ditto -c -k --sequesterRsrc --keepParent SwitchViewer.app "$release_dir/$release_name"
cd "$release_dir"
shasum -a 256 "$release_name" > "$release_name.sha256"
print "Release archive: $release_dir/$release_name"
