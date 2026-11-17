#!/bin/sh
# Downloads the pinned llama.cpp macOS build into dist/runtime/llama and verifies its checksum.
# The app bundles these binaries; nothing is installed on the user's Mac.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
# The pin lives in one place, shared with the app: Sources/AgentGateCore/Resources/engines.json.
PINS="$ROOT/Sources/AgentGateCore/Resources/engines.json"
TAG=$(plutil -extract engines.llama.tag raw -o - "$PINS")
SHA256=$(plutil -extract engines.llama.sha256 raw -o - "$PINS")
URL=$(plutil -extract engines.llama.url raw -o - "$PINS")
OUT="$ROOT/dist/runtime/llama"
if [ -f "$OUT/.tag" ] && [ "$(cat "$OUT/.tag")" = "$TAG" ]; then echo "llama.cpp $TAG already present"; exit 0; fi
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
curl -fsSL --retry 3 -o "$WORK/llama.tar.gz" "$URL"
echo "$SHA256  $WORK/llama.tar.gz" | shasum -a 256 -c -
mkdir -p "$WORK/x" && tar -xzf "$WORK/llama.tar.gz" -C "$WORK/x"
BIN=$(dirname "$(find "$WORK/x" -name llama-server -type f | head -1)")
rm -rf "$OUT" && mkdir -p "$OUT"
cp -R "$BIN"/. "$OUT"/
echo "$TAG" > "$OUT/.tag"
echo "llama.cpp $TAG in $OUT"
