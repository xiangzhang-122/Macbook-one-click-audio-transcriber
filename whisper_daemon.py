#!/usr/bin/env python3
import json
import os
import socket
import time
import wave

import numpy as np
import mlx_whisper

HOST = "127.0.0.1"
PORT = 8765
MODEL = "mlx-community/whisper-large-v3-turbo"
LOG_FILE = "/tmp/local-whisper-daemon.log"

# Keep this SHORT. Whisper's initial_prompt is decoder context, not an LLM instruction.
# A compact, punctuation-rich sample gives terminology + style bias with little latency overhead.
INITIAL_PROMPT = (
    "我们讨论 KV cache compression、FlashAttention、quantization、rate allocation、"
    "achievability、converse、AirComp 和 LLM inference。"
    "这个问题有什么核心 insight？我们需要把数学直觉表达得清楚、自然。"
)

REPLACEMENTS = {
    "KVCache": "KV cache",
    "KV Cache": "KV cache",
    "kv cache": "KV cache",
    "Flash Attention": "FlashAttention",
    "flash attention": "FlashAttention",
    "Flashattention": "FlashAttention",
    "Air Comp": "AirComp",
    "air comp": "AirComp",
    "overleaf": "Overleaf",
    "hammer spoon": "Hammerspoon",
    "Hammer Spoon": "Hammerspoon",
    "LLm": "LLM",
    "llm": "LLM",
    "Gpu": "GPU",
    "gpu": "GPU",
    "conversation": "converse",
}

os.environ["PATH"] = (
    "/opt/homebrew/bin:"
    "/usr/local/bin:"
    "/usr/bin:"
    "/bin:"
    "/usr/sbin:"
    "/sbin:"
    + os.environ.get("PATH", "")
)


def normalize_text(text: str) -> str:
    for wrong, correct in REPLACEMENTS.items():
        text = text.replace(wrong, correct)
    return text


def log(msg: str):
    line = f"{time.strftime('%Y-%m-%d %H:%M:%S')} {msg}\n"
    with open(LOG_FILE, "a", encoding="utf-8") as f:
        f.write(line)


def load_pcm16_wav(path: str):
    with wave.open(path, "rb") as wf:
        channels = wf.getnchannels()
        sample_width = wf.getsampwidth()
        sample_rate = wf.getframerate()
        nframes = wf.getnframes()
        frames = wf.readframes(nframes)

    if channels != 1:
        raise ValueError(f"expected mono WAV, got {channels} channels")
    if sample_width != 2:
        raise ValueError(f"expected PCM16 WAV, got sample width={sample_width}")
    if sample_rate != 16000:
        raise ValueError(f"expected 16000 Hz WAV, got {sample_rate} Hz")

    audio = np.frombuffer(frames, dtype="<i2").astype(np.float32) / 32768.0
    duration = nframes / sample_rate
    return audio, duration


def transcribe_file(path: str):
    audio, duration = load_pcm16_wav(path)
    log(f"request start; audio={duration:.2f}s")

    t0 = time.perf_counter()
    result = mlx_whisper.transcribe(
        audio,
        path_or_hf_repo=MODEL,
        language="zh",
        initial_prompt=INITIAL_PROMPT,
        verbose=None,
        temperature=0.0,
    )
    elapsed = time.perf_counter() - t0

    text = normalize_text((result.get("text") or "").strip())
    log(f"request done; inference={elapsed:.3f}s; text={text}")
    return text, elapsed


def warm_up():
    log(f"loading/warming model: {MODEL}")
    silence = np.zeros(16000, dtype=np.float32)

    t0 = time.perf_counter()
    mlx_whisper.transcribe(
        silence,
        path_or_hf_repo=MODEL,
        language="zh",
        initial_prompt=INITIAL_PROMPT,
        verbose=None,
        temperature=0.0,
    )
    log(f"READY; warm-up={time.perf_counter() - t0:.3f}s")


def handle(req: dict) -> dict:
    cmd = req.get("cmd")

    if cmd == "ping":
        return {"ok": True, "status": "ready", "model": MODEL}

    if cmd != "transcribe":
        return {"ok": False, "error": f"unknown command: {cmd!r}"}

    path = req.get("audio")
    if not path:
        return {"ok": False, "error": "missing audio path"}
    if not os.path.isfile(path):
        return {"ok": False, "error": f"audio file not found: {path}"}

    try:
        text, elapsed = transcribe_file(path)
        return {"ok": True, "text": text, "elapsed": round(elapsed, 4)}
    except Exception as exc:
        log(f"ERROR {exc!r}")
        return {"ok": False, "error": repr(exc)}


def serve():
    warm_up()

    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as server:
        server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        server.bind((HOST, PORT))
        server.listen(8)
        log(f"listening on {HOST}:{PORT}")

        while True:
            conn, _ = server.accept()
            with conn:
                f = conn.makefile("rwb")
                line = f.readline()
                if not line:
                    continue

                try:
                    req = json.loads(line.decode("utf-8"))
                    resp = handle(req)
                except Exception as exc:
                    resp = {"ok": False, "error": repr(exc)}

                f.write((json.dumps(resp, ensure_ascii=False) + "\n").encode("utf-8"))
                f.flush()


if __name__ == "__main__":
    try:
        serve()
    except Exception as exc:
        log(f"FATAL {exc!r}")
        raise
