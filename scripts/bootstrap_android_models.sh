#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ASSETS_DIR="$ROOT_DIR/WhisperAndroid/app/src/main/assets"
MODELS_DIR="$ASSETS_DIR/models"
BENCHMARK_DIR="$ASSETS_DIR/benchmark-clips"
IOS_BENCHMARK_DIR="$ROOT_DIR/WhisperiOS/Models/benchmark-clips"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/whisperandroid-models.XXXXXX")"
FORCE_DOWNLOAD="${FORCE_DOWNLOAD:-0}"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

log() {
  printf '[bootstrap_android_models] %s\n' "$*"
}

fail() {
  printf '[bootstrap_android_models] ERROR: %s\n' "$*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

has_file() {
  [[ -f "$1" && -s "$1" ]]
}

download_file() {
  local url="$1"
  local dst="$2"
  local tmp="${dst}.part"

  if [[ "$FORCE_DOWNLOAD" != "1" ]] && has_file "$dst"; then
    log "Skip existing: ${dst#$ROOT_DIR/}"
    return
  fi

  mkdir -p "$(dirname "$dst")"
  log "Downloading: ${dst#$ROOT_DIR/}"
  curl -fL --retry 3 --retry-delay 2 -o "$tmp" "$url"
  mv "$tmp" "$dst"
}

extract_sherpa_whisper() {
  local archive_url="$1"
  local output_dir="$2"
  local encoder_name="$3"
  local decoder_name="$4"
  local tokens_name="$5"

  local archive_path="$TMP_DIR/sherpa-whisper.tar.bz2"
  local extract_dir="$TMP_DIR/sherpa-whisper"

  mkdir -p "$output_dir"

  if [[ "$FORCE_DOWNLOAD" != "1" ]] && has_file "$output_dir/$encoder_name" && has_file "$output_dir/$decoder_name" && has_file "$output_dir/$tokens_name"; then
    log "Skip existing: ${output_dir#$ROOT_DIR/}"
    return
  fi

  rm -rf "$extract_dir"
  mkdir -p "$extract_dir"

  download_file "$archive_url" "$archive_path"
  tar -xjf "$archive_path" -C "$extract_dir"

  local encoder
  local decoder
  local tokens
  encoder="$(find "$extract_dir" -type f -iname '*encoder.onnx' ! -iname '*int8*' | sort | head -n1)"
  decoder="$(find "$extract_dir" -type f -iname '*decoder.onnx' ! -iname '*int8*' | sort | head -n1)"
  tokens="$(find "$extract_dir" -type f -iname '*tokens.txt' | sort | head -n1)"

  [[ -n "$encoder" ]] || fail "Cannot find encoder.onnx in sherpa archive"
  [[ -n "$decoder" ]] || fail "Cannot find decoder.onnx in sherpa archive"
  [[ -n "$tokens" ]] || fail "Cannot find tokens.txt in sherpa archive"

  cp "$encoder" "$output_dir/$encoder_name"
  cp "$decoder" "$output_dir/$decoder_name"
  cp "$tokens" "$output_dir/$tokens_name"
  log "Prepared Whisper model at ${output_dir#$ROOT_DIR/}"
}

extract_runanywhere_onnx() {
  local model_id="$1"
  local archive_url="$2"
  local output_dir="$MODELS_DIR/runanywhere/$model_id"
  local archive_path="$TMP_DIR/${model_id}.tar.bz2"
  local extract_dir="$TMP_DIR/${model_id}"

  mkdir -p "$output_dir"

  if [[ "$FORCE_DOWNLOAD" != "1" ]] && has_file "$output_dir/encoder.onnx" && has_file "$output_dir/decoder.onnx" && has_file "$output_dir/tokens.txt"; then
    log "Skip existing: ${output_dir#$ROOT_DIR/}"
    return
  fi

  rm -rf "$extract_dir"
  mkdir -p "$extract_dir"

  download_file "$archive_url" "$archive_path"
  tar -xjf "$archive_path" -C "$extract_dir"

  local encoder
  local decoder
  local tokens
  encoder="$(find "$extract_dir" -type f -iname '*encoder.int8.onnx' | sort | head -n1)"
  decoder="$(find "$extract_dir" -type f -iname '*decoder.int8.onnx' | sort | head -n1)"
  tokens="$(find "$extract_dir" -type f -iname '*tokens.txt' | sort | head -n1)"

  if [[ -z "$encoder" ]]; then
    encoder="$(find "$extract_dir" -type f -iname '*encoder.onnx' ! -iname '*int8*' | sort | head -n1)"
  fi
  if [[ -z "$decoder" ]]; then
    decoder="$(find "$extract_dir" -type f -iname '*decoder.onnx' ! -iname '*int8*' | sort | head -n1)"
  fi

  [[ -n "$encoder" ]] || fail "Cannot find encoder.onnx for ${model_id}"
  [[ -n "$decoder" ]] || fail "Cannot find decoder.onnx for ${model_id}"
  [[ -n "$tokens" ]] || fail "Cannot find tokens.txt for ${model_id}"

  cp "$encoder" "$output_dir/encoder.onnx"
  cp "$decoder" "$output_dir/decoder.onnx"
  cp "$tokens" "$output_dir/tokens.txt"
  log "Prepared RunAnywhere model: $model_id"
}

sync_benchmark_clips() {
  mkdir -p "$BENCHMARK_DIR"

  local files=(
    "earnings22_1_4482311_3_62.wav"
    "earnings22_1_4482311_3_62.txt"
    "earnings22_2_4482249_1600_1664.wav"
    "earnings22_2_4482249_1600_1664.txt"
    "earnings22_3_4483589_261_321.wav"
    "earnings22_3_4483589_261_321.txt"
    "fleurs_ja_1837_clip4.wav"
    "fleurs_ja_1837_clip4.txt"
    "fleurs_zh_1883_clip5.wav"
    "fleurs_zh_1883_clip5.txt"
    "fleurs_zh_en_mix_1805_1830_clip6.wav"
    "fleurs_zh_en_mix_1805_1830_clip6.txt"
  )

  if [[ ! -d "$IOS_BENCHMARK_DIR" ]]; then
    fail "Missing source benchmark clips directory: $IOS_BENCHMARK_DIR"
  fi

  local name
  for name in "${files[@]}"; do
    if [[ ! -f "$IOS_BENCHMARK_DIR/$name" ]]; then
      fail "Missing benchmark source file: $IOS_BENCHMARK_DIR/$name"
    fi
    cp "$IOS_BENCHMARK_DIR/$name" "$BENCHMARK_DIR/$name"
  done

  log "Benchmark clips synced to ${BENCHMARK_DIR#$ROOT_DIR/}"
}

main() {
  require_cmd curl
  require_cmd tar

  mkdir -p "$MODELS_DIR/whisper/tiny"
  mkdir -p "$MODELS_DIR/nexa/whisper"
  mkdir -p "$MODELS_DIR/runanywhere/whisper-tiny-onnx"
  mkdir -p "$MODELS_DIR/runanywhere/whisper-base-onnx"

  extract_sherpa_whisper \
    "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-whisper-tiny.tar.bz2" \
    "$MODELS_DIR/whisper/tiny" \
    "tiny-encoder.onnx" \
    "tiny-decoder.onnx" \
    "tiny-tokens.txt"

  extract_runanywhere_onnx \
    "whisper-tiny-onnx" \
    "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-whisper-tiny.tar.bz2"

  extract_runanywhere_onnx \
    "whisper-base-onnx" \
    "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-whisper-base.tar.bz2"

  download_file \
    "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.bin" \
    "$MODELS_DIR/nexa/whisper/ggml-tiny.bin"

  download_file \
    "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin" \
    "$MODELS_DIR/nexa/whisper/ggml-base.bin"

  sync_benchmark_clips

  log "Android models and benchmark assets are ready."
}

main "$@"
