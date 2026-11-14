#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

app="$(scripts/build-app.sh)"
open "$app"
