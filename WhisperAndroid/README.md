# WhisperAndroid

Offline STT/TTS test app with:
- Whisper (Sherpa ONNX)
- Nexa SDK (`whisper_cpp` backend)
- RunAnywhere SDK (ONNX backend)

## Before Build

This repository does not commit AI model binaries for Android.

Run:

```bash
./scripts/bootstrap_android_models.sh
```

The script will:
- Download Whisper tiny model for Sherpa.
- Download RunAnywhere ONNX models (`whisper-tiny-onnx`, `whisper-base-onnx`).
- Download Nexa whisper.cpp models (`ggml-tiny.bin`, `ggml-base.bin`).
- Sync benchmark clips into Android assets.

Use `FORCE_DOWNLOAD=1` to re-download:

```bash
FORCE_DOWNLOAD=1 ./scripts/bootstrap_android_models.sh
```

## Build

```bash
cd WhisperAndroid
./gradlew :app:assembleDebug
```
