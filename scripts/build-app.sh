#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache"

swift build -c release --disable-sandbox
binary_dir="$(swift build -c release --disable-sandbox --show-bin-path)"

app="$PWD/dist/herd-db.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"

cp "$binary_dir/herd-db" "$app/Contents/MacOS/herd-db"
cp Resources/Info.plist "$app/Contents/Info.plist"

codesign --force --deep --sign - "$app" >/dev/null
codesign --verify --strict "$app"

printf '%s\n' "$app"
