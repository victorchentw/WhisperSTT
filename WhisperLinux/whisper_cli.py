#!/usr/bin/env python3
import os
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
import wave
from collections import deque
from dataclasses import dataclass
from typing import Deque, List, Optional, Tuple

SAMPLE_RATE = 16000
CHANNELS = 1
SAMPLE_WIDTH = 2  # 16-bit
READ_CHUNK_BYTES = 4096


@dataclass
class SourceInfo:
    index: str
    name: str
    driver: str
    state: str


class StopFlag:
    def __init__(self) -> None:
        self._event = threading.Event()

    def stop(self) -> None:
        self._event.set()

    def is_set(self) -> bool:
        return self._event.is_set()


def check_cmd(name: str) -> bool:
    return shutil.which(name) is not None


def run_capture(cmd: List[str]) -> subprocess.Popen:
    return subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)


def list_sources() -> List[SourceInfo]:
    out = subprocess.check_output(["pactl", "list", "short", "sources"], text=True)
    sources: List[SourceInfo] = []
    for line in out.strip().splitlines():
        parts = line.split("\t")
        if len(parts) >= 4:
            sources.append(SourceInfo(parts[0], parts[1], parts[2], parts[3]))
    return sources


def get_default_sink() -> Optional[str]:
    out = subprocess.check_output(["pactl", "info"], text=True)
    for line in out.splitlines():
        if line.startswith("Default Sink:"):
            return line.split(":", 1)[1].strip()
    return None


def choose_source() -> str:
    sources = list_sources()
    if not sources:
        raise RuntimeError("No PulseAudio sources found.")

    print("Available input sources:")
    for s in sources:
        print(f"  [{s.index}] {s.name} ({s.state})")
    while True:
        choice = input("Select source index: ").strip()
        for s in sources:
            if s.index == choice:
                return s.name
        print("Invalid selection.")


def choose_system_monitor_source() -> str:
    default_sink = get_default_sink()
    if not default_sink:
        raise RuntimeError("Could not detect default sink.")
    monitor_name = f"{default_sink}.monitor"
    sources = list_sources()
    for s in sources:
        if s.name == monitor_name:
            return monitor_name
    raise RuntimeError(
        f"Monitor source not found for default sink: {monitor_name}."
    )


def prompt_choice(prompt: str, options: List[str], default_index: int = 0) -> str:
    for i, opt in enumerate(options, start=1):
        marker = "*" if i - 1 == default_index else " "
        print(f"  {marker} {i}. {opt}")
    while True:
        raw = input(f"{prompt} [default {default_index + 1}]: ").strip()
        if not raw:
            return options[default_index]
        if raw.isdigit():
            idx = int(raw) - 1
            if 0 <= idx < len(options):
                return options[idx]
        print("Invalid selection.")


def prompt_float(prompt: str, default: float, min_val: float) -> float:
    while True:
        raw = input(f"{prompt} [default {default}]: ").strip()
        if not raw:
            return default
        try:
            value = float(raw)
            if value >= min_val:
                return value
        except ValueError:
            pass
        print("Invalid value.")


def prompt_string(prompt: str, default: str) -> str:
    raw = input(f"{prompt} [default {default}]: ").strip()
    return raw if raw else default


def write_wav(path: str, pcm_bytes: bytes) -> None:
    with wave.open(path, "wb") as wf:
        wf.setnchannels(CHANNELS)
        wf.setsampwidth(SAMPLE_WIDTH)
        wf.setframerate(SAMPLE_RATE)
        wf.writeframes(pcm_bytes)


def merge_text(prev: str, new: str) -> str:
    prev = prev.strip()
    new = new.strip()
    if not prev:
        return new
    if not new:
        return prev

    prev_words = prev.split()
    new_words = new.split()
    max_check = min(6, len(prev_words), len(new_words))
    for k in range(max_check, 0, -1):
        if prev_words[-k:] == new_words[:k]:
            return " ".join(prev_words[:-k] + new_words)
    return f"{prev} {new}".strip()


def build_command(template: str, binary: str, model: str, audio: str, language: str) -> List[str]:
    cmd = template.format(binary=binary, model=model, audio=audio, lang=language)
    return shlex.split(cmd)


def run_transcribe(cmd: List[str]) -> Tuple[str, float]:
    start = time.time()
    result = subprocess.run(cmd, capture_output=True, text=True)
    latency = time.time() - start
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or "Transcription command failed")
    text = result.stdout.strip()
    return text, latency


def pick_language() -> str:
    return prompt_string("Language (auto/en/zh/ja...)", "auto")


def ensure_dependencies() -> None:
    if not check_cmd("pactl"):
        raise RuntimeError("Missing 'pactl'. Install PulseAudio utilities.")
    if not check_cmd("parec"):
        raise RuntimeError("Missing 'parec'. Install PulseAudio utilities.")


def capture_clip(source: str, cmd_template: str, binary: str, model: str, language: str) -> None:
    os.makedirs("recordings", exist_ok=True)
    stop_flag = StopFlag()

    def wait_stop() -> None:
        input("Recording... press ENTER to stop. ")
        stop_flag.stop()

    thread = threading.Thread(target=wait_stop, daemon=True)
    thread.start()

    cmd = [
        "parec",
        "--device",
        source,
        "--format=s16le",
        f"--rate={SAMPLE_RATE}",
        f"--channels={CHANNELS}",
    ]
    proc = run_capture(cmd)

    pcm = bytearray()
    try:
        while not stop_flag.is_set():
            data = proc.stdout.read(READ_CHUNK_BYTES)
            if not data:
                break
            pcm.extend(data)
    finally:
        proc.terminate()
        proc.wait(timeout=2)

    if not pcm:
        print("No audio captured.")
        return

    wav_path = os.path.join("recordings", f"clip_{int(time.time())}.wav")
    write_wav(wav_path, bytes(pcm))

    cmd = build_command(cmd_template, binary, model, wav_path, language)
    print("Transcribing...")
    text, latency = run_transcribe(cmd)
    audio_sec = len(pcm) / (SAMPLE_RATE * SAMPLE_WIDTH)
    rtf = latency / audio_sec if audio_sec > 0 else 0
    print("\n=== Transcription ===")
    print(text)
    print(f"\nLatency: {latency:.2f}s | Audio: {audio_sec:.2f}s | RTF: {rtf:.2f}")


def capture_streaming(
    source: str,
    cmd_template: str,
    binary: str,
    model: str,
    language: str,
    chunk_seconds: float,
    overlap_seconds: float,
) -> None:
    stop_flag = StopFlag()

    def handle_sigint(signum, frame):
        stop_flag.stop()

    signal.signal(signal.SIGINT, handle_sigint)

    cmd = [
        "parec",
        "--device",
        source,
        "--format=s16le",
        f"--rate={SAMPLE_RATE}",
        f"--channels={CHANNELS}",
    ]
    proc = run_capture(cmd)

    chunk_bytes = int(chunk_seconds * SAMPLE_RATE * SAMPLE_WIDTH)
    overlap_bytes = int(overlap_seconds * SAMPLE_RATE * SAMPLE_WIDTH)
    buffer = bytearray()
    confirmed_text = ""

    print("Streaming... press Ctrl+C to stop.")

    try:
        while not stop_flag.is_set():
            data = proc.stdout.read(READ_CHUNK_BYTES)
            if not data:
                break
            buffer.extend(data)
            if len(buffer) < chunk_bytes:
                continue

            chunk = bytes(buffer[:chunk_bytes])
            buffer = buffer[chunk_bytes - overlap_bytes :]

            with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tmp:
                wav_path = tmp.name
            write_wav(wav_path, chunk)

            cmd = build_command(cmd_template, binary, model, wav_path, language)
            text, latency = run_transcribe(cmd)
            os.unlink(wav_path)

            confirmed_text = merge_text(confirmed_text, text)
            audio_sec = len(chunk) / (SAMPLE_RATE * SAMPLE_WIDTH)
            rtf = latency / audio_sec if audio_sec > 0 else 0

            print("\n--- Partial ---")
            print(confirmed_text)
            print(f"Latency: {latency:.2f}s | Audio: {audio_sec:.2f}s | RTF: {rtf:.2f}")
    finally:
        proc.terminate()
        proc.wait(timeout=2)

    print("\n=== Final Transcription ===")
    print(confirmed_text)


def main() -> None:
    try:
        ensure_dependencies()
    except RuntimeError as err:
        print(f"Error: {err}")
        sys.exit(1)

    mode = prompt_choice("Mode", ["streaming", "clip"], default_index=0)
    input_type = prompt_choice(
        "Input source",
        ["microphone", "system audio (speaker monitor)", "choose source"],
        default_index=0,
    )

    try:
        if input_type == "microphone":
            source = choose_source()
        elif input_type == "system audio (speaker monitor)":
            source = choose_system_monitor_source()
        else:
            source = choose_source()
    except RuntimeError as err:
        print(f"Error: {err}")
        sys.exit(1)

    language = pick_language()

    binary = prompt_string("Whisper binary path", "./whisper.cpp/main")
    model = prompt_string("Model path", "./models/ggml-tiny.bin")
    cmd_template = prompt_string(
        "Command template (use {binary} {model} {audio} {lang})",
        "{binary} -m {model} -f {audio} -l {lang} -nt",
    )

    if mode == "clip":
        capture_clip(source, cmd_template, binary, model, language)
    else:
        chunk_seconds = prompt_float("Chunk length (seconds)", 4.0, 1.0)
        overlap_seconds = prompt_float("Overlap (seconds)", 1.0, 0.0)
        if overlap_seconds >= chunk_seconds:
            print("Overlap must be smaller than chunk length.")
            sys.exit(1)
        capture_streaming(source, cmd_template, binary, model, language, chunk_seconds, overlap_seconds)


if __name__ == "__main__":
    main()
