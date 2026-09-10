#!/bin/bash
set -euo pipefail
clip_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$clip_root"
swift build --product ClipName
clip_bin="$(swift build --show-bin-path)"
clip_stage="$(mktemp -d)"
clip_app="$clip_stage/ClipName.app"
mkdir -p "$clip_app/Contents/MacOS" "$clip_app/Contents/Resources"
install -m 755 "$clip_bin/ClipName" "$clip_app/Contents/MacOS/ClipName"
cp Packaging/Info.plist "$clip_app/Contents/Info.plist"
cp Sources/EchoRename/Resources/scene_namer.py "$clip_app/Contents/Resources/scene_namer.py"
codesign --force --sign - "$clip_app"
codesign --verify --strict "$clip_app"
mkdir -p "$HOME/Applications"
if [ -e "$HOME/Applications/ClipName.app" ]; then
    clip_backup="$HOME/Library/Application Support/ClipName/Backups/$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$clip_backup"
    mv "$HOME/Applications/ClipName.app" "$clip_backup/ClipName.app"
fi
mv "$clip_app" "$HOME/Applications/ClipName.app"
rmdir "$clip_stage"
echo "Installed $HOME/Applications/ClipName.app"
