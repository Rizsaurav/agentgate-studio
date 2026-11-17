#!/bin/sh
# Downloads the pinned OpenCode macOS build into dist/runtime/opencode and verifies its checksum.
# OpenCode (MIT) is the agent harness: tools, terminal, permissions. The app bundles it.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
# The pin lives in one place, shared with the app: Sources/AgentGateCore/Resources/engines.json.
PINS="$ROOT/Sources/AgentGateCore/Resources/engines.json"
TAG=$(plutil -extract engines.opencode.tag raw -o - "$PINS")
SHA256=$(plutil -extract engines.opencode.sha256 raw -o - "$PINS")
URL=$(plutil -extract engines.opencode.url raw -o - "$PINS")
OUT="$ROOT/dist/runtime/opencode"
if [ -f "$OUT/.tag" ] && [ "$(cat "$OUT/.tag")" = "$TAG" ]; then echo "OpenCode $TAG already present"; exit 0; fi
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
curl -fsSL --retry 3 -o "$WORK/opencode.zip" "$URL"
echo "$SHA256  $WORK/opencode.zip" | shasum -a 256 -c -
rm -rf "$OUT" && mkdir -p "$OUT"
unzip -q "$WORK/opencode.zip" -d "$OUT"
echo "$TAG" > "$OUT/.tag"
echo "OpenCode $TAG in $OUT"
