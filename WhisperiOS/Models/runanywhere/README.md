RunAnywhere bundled models (ONNX)

Model binaries are not committed to git.

To download the RunAnywhere ONNX STT models used by this app:

1) From repo root, run:
   ./scripts/bootstrap_ios_models.sh
2) Rebuild the app.

Model IDs configured in the app:
  - whisper-tiny-onnx
  - whisper-base-onnx

Source archives (official `k2-fsa/sherpa-onnx` releases):
  - sherpa-onnx-whisper-tiny.tar.bz2
  - sherpa-onnx-whisper-base.tar.bz2

Expected files per model folder:
  - encoder.onnx
  - decoder.onnx
  - tokens.txt
