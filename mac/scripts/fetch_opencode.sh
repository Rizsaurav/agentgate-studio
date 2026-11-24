#!/bin/sh
# Downloads the pinned OpenCode macOS build into dist/runtime/opencode and verifies its checksum.
# OpenCode (MIT) is the agent harness: tools, terminal, permissions. The app bundles it.
set -eu
TAG=v1.19.5
SHA256=c1c9e62521192192ef4c3ed1355ada2144055bddb61682217e997b03c55203c1
URL="https://github.com/anomalyco/opencode/releases/download/$TAG/opencode-darwin-arm64.zip"
ROOT=$(cd "$(dirname "$0")/.." && pwd)
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
