#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/DeepSeekHarnessMenuBar.app"
TARGET="$HOME/Applications/DeepSeekHarnessMenuBar.app"

if [[ ! -d "$APP" ]]; then
  "$ROOT/build-app.sh"
fi
mkdir -p "$HOME/Applications"
rm -rf "$TARGET"
cp -R "$APP" "$TARGET"
open "$TARGET"
echo "Installed and launched: $TARGET"
