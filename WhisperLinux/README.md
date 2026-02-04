# WhisperLinux (CLI)

Offline STT CLI for Linux using PulseAudio capture and whisper.cpp.

## Requirements
- PulseAudio utilities: `pactl`, `parec`
- Python 3
- whisper.cpp binary + model file

## Setup (example)
1. Build whisper.cpp (from https://github.com/ggml-org/whisper.cpp)
2. The model `models/ggml-tiny.bin` is already included.
3. Run the CLI:

```bash
./whisper_cli.py
```

## Notes
- Use **system audio** to capture speaker output (monitor source).
- Use **microphone** to capture mic input.
- For streaming, the app runs chunk+overlap decoding (default 4s / 1s).
- If your whisper.cpp binary uses different flags, edit the command template when prompted.
