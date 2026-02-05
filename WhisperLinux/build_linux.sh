#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "$0")" && pwd)
THIRD_PARTY="$ROOT_DIR/third_party"
WHISPER_CPP_DIR="$THIRD_PARTY/whisper.cpp"
BUILD_DIR="$ROOT_DIR/build"
BIN_DIR="$ROOT_DIR/bin"

if ! command -v cmake >/dev/null 2>&1; then
  echo "cmake is required" >&2
  exit 1
fi

if ! command -v g++ >/dev/null 2>&1; then
  echo "g++ is required" >&2
  exit 1
fi

if ! command -v xxd >/dev/null 2>&1; then
  echo "xxd is required (install vim-common)" >&2
  exit 1
fi

if [ ! -f "$ROOT_DIR/models/ggml-tiny.bin" ]; then
  echo "Missing model: $ROOT_DIR/models/ggml-tiny.bin" >&2
  exit 1
fi

mkdir -p "$THIRD_PARTY"
if [ ! -d "$WHISPER_CPP_DIR" ]; then
  git clone https://github.com/ggml-org/whisper.cpp "$WHISPER_CPP_DIR"
fi

cmake -S "$ROOT_DIR/native" -B "$BUILD_DIR" -DWHISPER_CPP_DIR="$WHISPER_CPP_DIR" -DCMAKE_BUILD_TYPE=Release
cmake --build "$BUILD_DIR" -j

mkdir -p "$BIN_DIR"
cp "$BUILD_DIR/whisper_cli" "$BIN_DIR/whisper_cli"

strip "$BIN_DIR/whisper_cli" 2>/dev/null || true

echo "Built: $BIN_DIR/whisper_cli"
