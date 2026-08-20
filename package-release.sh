#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
VERSION="${1:-}"

if [[ -z "$VERSION" ]]; then
  echo "Usage: $0 <version>" >&2
  echo "Example: $0 1.1.0" >&2
  exit 1
fi

VERSION="${VERSION#v}"
ARCHIVE="$ROOT/DeepSeekHarnessMenuBar-v$VERSION.zip"

DSH_VERSION="$VERSION" "$ROOT/build-app.sh"
rm -f "$ARCHIVE"
ditto -c -k --norsrc --keepParent \
  "$ROOT/DeepSeekHarnessMenuBar.app" \
  "$ARCHIVE"

echo "Release asset: $ARCHIVE"
