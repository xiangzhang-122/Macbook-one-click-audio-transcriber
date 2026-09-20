#!/usr/bin/env python3
import json
import socket
import sys

HOST = "127.0.0.1"
PORT = 8765
TIMEOUT = 20.0


def main():
    if len(sys.argv) != 2:
        print("usage: whisper_client.py <audio.wav>", file=sys.stderr)
        sys.exit(2)

    req = {
        "cmd": "transcribe",
        "audio": sys.argv[1],
    }

    try:
        with socket.create_connection((HOST, PORT), timeout=TIMEOUT) as sock:
            sock.settimeout(TIMEOUT)
            f = sock.makefile("rwb")

            f.write((json.dumps(req) + "\n").encode("utf-8"))
            f.flush()

            line = f.readline()
            if not line:
                raise RuntimeError("daemon returned no response")

        resp = json.loads(line.decode("utf-8"))

        if not resp.get("ok"):
            print(resp.get("error", "unknown daemon error"), file=sys.stderr)
            sys.exit(1)

        text = (resp.get("text") or "").strip()
        elapsed = resp.get("elapsed")

        # stdout must contain ONLY transcript; Hammerspoon pastes stdout.
        print(text)

        # Diagnostic latency goes to stderr so it is never pasted.
        if elapsed is not None:
            print(f"[whisper inference {elapsed:.3f}s]", file=sys.stderr)

    except Exception as exc:
        print(f"client error: {exc}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
