#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache"

swift build -c release --disable-sandbox >&2
binary_dir="$(swift build -c release --disable-sandbox --show-bin-path)"

app="$PWD/dist/herd.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"

cp "$binary_dir/herd-db" "$app/Contents/MacOS/herd-db"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
cp Resources/AppIconDark.icns "$app/Contents/Resources/AppIconDark.icns"
mkdir -p "$app/Contents/Resources/Branding"
cp Resources/Branding/*.png "$app/Contents/Resources/Branding/"

codesign --force --deep --sign - "$app" >/dev/null
codesign --verify --strict "$app"

printf '%s\n' "$app"
