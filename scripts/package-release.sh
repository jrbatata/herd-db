#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

app="$(scripts/build-app.sh)"
version="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)"
arch="$(uname -m)"

zip_path="$PWD/dist/herd-${version}-macos-${arch}.zip"
dmg_path="$PWD/dist/herd-${version}-macos-${arch}.dmg"
dmg_staging="$PWD/dist/.dmg-staging"

rm -f "$zip_path" "$dmg_path" "$PWD/dist/herd-db-${version}-macos.zip"
rm -rf "$dmg_staging"

# 1. Empacota .zip preservando estrutura e assinatura do bundle macOS
ditto -c -k --sequesterRsrc --keepParent "$app" "$zip_path"

# 2. Empacota .dmg com atalho para /Applications
mkdir -p "$dmg_staging"
cp -R "$app" "$dmg_staging/herd.app"
ln -s /Applications "$dmg_staging/Applications"
hdiutil create -volname "herd ${version}" \
    -srcfolder "$dmg_staging" \
    -ov -format UDZO \
    "$dmg_path" >/dev/null
rm -rf "$dmg_staging"

shasum -a 256 "$zip_path" "$dmg_path" > "$PWD/dist/SHA256SUMS.txt"

printf 'Artefatos gerados em dist/:\n  %s\n  %s\n  %s\n' "$zip_path" "$dmg_path" "$PWD/dist/SHA256SUMS.txt"
