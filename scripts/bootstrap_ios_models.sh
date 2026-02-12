#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODELS_DIR="$ROOT_DIR/WhisperiOS/Models"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/whisperios-models.XXXXXX")"
FORCE_DOWNLOAD="${FORCE_DOWNLOAD:-0}"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

log() {
  printf '[bootstrap_ios_models] %s\n' "$*"
}

fail() {
  printf '[bootstrap_ios_models] ERROR: %s\n' "$*" >&2
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

download_hf_tree() {
  local repo_base_url="$1"
  local dst_root="$2"
  shift 2

  local rel
  for rel in "$@"; do
    download_file "${repo_base_url}/${rel}" "${dst_root}/${rel}"
  done
}

sync_runanywhere_model() {
  local model_id="$1"
  local archive_url="$2"
  local dst_dir="$MODELS_DIR/runanywhere/${model_id}"
  local extract_dir="$TMP_DIR/${model_id}"
  local archive_path="$TMP_DIR/${model_id}.tar.bz2"
  local encoder
  local decoder
  local tokens

  if [[ "$FORCE_DOWNLOAD" != "1" ]] && has_file "$dst_dir/encoder.onnx" && has_file "$dst_dir/decoder.onnx" && has_file "$dst_dir/tokens.txt"; then
    log "Skip existing: WhisperiOS/Models/runanywhere/${model_id}"
    return
  fi

  mkdir -p "$extract_dir"
  download_file "$archive_url" "$archive_path"
  tar -xjf "$archive_path" -C "$extract_dir"

  encoder="$(find "$extract_dir" -type f -iname '*encoder.onnx' ! -iname '*int8*' | sort | head -n1)"
  decoder="$(find "$extract_dir" -type f -iname '*decoder.onnx' ! -iname '*int8*' | sort | head -n1)"
  tokens="$(find "$extract_dir" -type f -iname '*tokens.txt' | sort | head -n1)"

  [[ -n "$encoder" ]] || fail "Cannot find full-precision encoder in archive for ${model_id}"
  [[ -n "$decoder" ]] || fail "Cannot find full-precision decoder in archive for ${model_id}"
  [[ -n "$tokens" ]] || fail "Cannot find tokens.txt in archive for ${model_id}"

  mkdir -p "$dst_dir"
  cp "$encoder" "$dst_dir/encoder.onnx"
  cp "$decoder" "$dst_dir/decoder.onnx"
  cp "$tokens" "$dst_dir/tokens.txt"
  log "Prepared RunAnywhere model: ${model_id}"
}

main() {
  require_cmd curl
  require_cmd tar

  log "Root: $ROOT_DIR"

  # 1) RunAnywhere ONNX models (official sherpa-onnx multilingual releases)
  sync_runanywhere_model \
    "whisper-tiny-onnx" \
    "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-whisper-tiny.tar.bz2"
  sync_runanywhere_model \
    "whisper-base-onnx" \
    "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-whisper-base.tar.bz2"

  # 2) WhisperKit tiny CoreML model
  download_hf_tree \
    "https://huggingface.co/argmaxinc/whisperkit-coreml/resolve/main/openai_whisper-tiny" \
    "$MODELS_DIR/whisperkit-coreml/openai_whisper-tiny" \
    "config.json" \
    "generation_config.json" \
    "AudioEncoder.mlmodelc/analytics/coremldata.bin" \
    "AudioEncoder.mlmodelc/coremldata.bin" \
    "AudioEncoder.mlmodelc/metadata.json" \
    "AudioEncoder.mlmodelc/model.mil" \
    "AudioEncoder.mlmodelc/model.mlmodel" \
    "AudioEncoder.mlmodelc/weights/weight.bin" \
    "TextDecoder.mlmodelc/analytics/coremldata.bin" \
    "TextDecoder.mlmodelc/coremldata.bin" \
    "TextDecoder.mlmodelc/metadata.json" \
    "TextDecoder.mlmodelc/model.mil" \
    "TextDecoder.mlmodelc/model.mlmodel" \
    "TextDecoder.mlmodelc/weights/weight.bin" \
    "MelSpectrogram.mlmodelc/analytics/coremldata.bin" \
    "MelSpectrogram.mlmodelc/coremldata.bin" \
    "MelSpectrogram.mlmodelc/metadata.json" \
    "MelSpectrogram.mlmodelc/model.mil" \
    "MelSpectrogram.mlmodelc/weights/weight.bin"

  # 3) Whisper tokenizer for tiny
  download_hf_tree \
    "https://huggingface.co/openai/whisper-tiny/resolve/main" \
    "$MODELS_DIR/tokenizers/openai-whisper-tiny" \
    "added_tokens.json" \
    "config.json" \
    "generation_config.json" \
    "merges.txt" \
    "normalizer.json" \
    "preprocessor_config.json" \
    "special_tokens_map.json" \
    "tokenizer.json" \
    "tokenizer_config.json" \
    "vocab.json"

  # 4) Nexa default STT model
  download_hf_tree \
    "https://huggingface.co/NexaAI/parakeet-tdt-0.6b-v3-ane/resolve/main" \
    "$MODELS_DIR/nexa/parakeet-tdt-0.6b-v3-ane" \
    ".gitattributes" \
    "config.json" \
    "nexa.manifest" \
    "tokenizer.vocab" \
    "parakeet_emb.npy" \
    "pos_emb_4_3.npy" \
    "ParakeetEncoder.mlmodelc/analytics/coremldata.bin" \
    "ParakeetEncoder.mlmodelc/coremldata.bin" \
    "ParakeetEncoder.mlmodelc/model.mil" \
    "ParakeetEncoder.mlmodelc/weights/weight.bin" \
    "ParakeetDecRnn.mlmodelc/analytics/coremldata.bin" \
    "ParakeetDecRnn.mlmodelc/coremldata.bin" \
    "ParakeetDecRnn.mlmodelc/metadata.json" \
    "ParakeetDecRnn.mlmodelc/model.mil" \
    "ParakeetDecRnn.mlmodelc/weights/weight.bin" \
    "ParakeetJoint.mlmodelc/analytics/coremldata.bin" \
    "ParakeetJoint.mlmodelc/coremldata.bin" \
    "ParakeetJoint.mlmodelc/metadata.json" \
    "ParakeetJoint.mlmodelc/model.mil" \
    "ParakeetJoint.mlmodelc/weights/weight.bin"

  log "All required iOS STT models are ready."
}

main "$@"
