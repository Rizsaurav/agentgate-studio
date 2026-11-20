#!/bin/sh
# Downloads the pinned llama.cpp macOS build into dist/runtime/llama and verifies its checksum.
# The app bundles these binaries; nothing is installed on the user's Mac.
set -eu
TAG=b11765
SHA256=411350ac7aa943907db7867b3b3a112166f60d7dc9748c7f7528f3e5f223a4f2
URL="https://github.com/ggml-org/llama.cpp/releases/download/$TAG/llama-$TAG-bin-macos-arm64.tar.gz"
ROOT=$(cd "$(dirname "$0")/.." && pwd)
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
