# WhisperLinux (CLI)

Offline STT CLI for Linux using PulseAudio capture and **whisper.cpp embedded in a single executable**.

## Requirements (build machine)
- PulseAudio utilities: `pactl`, `parec`
- `cmake`, `g++`, `xxd` (vim-common)
- git

## Build
The model `models/ggml-tiny.bin` is already included and will be **embedded into the binary**.

```bash
./build_linux.sh
```

Output: `bin/whisper_cli` (single executable you can copy to other Ubuntu machines).

## Run
```bash
./bin/whisper_cli
```

## Notes
- Uses PulseAudio (`pactl` + `parec`) to list sources and capture.
- **System audio** uses the default sink monitor (like kazam “sound from speakers”).
- **Microphone** uses any available input source.
- Streaming uses chunk + overlap (default 4s / 1s).
