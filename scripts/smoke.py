#!/usr/bin/env python3
"""Smoke test: generate a Chinese audio clip with the system TTS, call every endpoint and check for non-empty text.

Usage: scripts/smoke.py [server URL], default http://127.0.0.1:8008; set SOTTOVOCE_TOKEN if the server requires a token.
"""

import base64
import json
import os
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request
import uuid
from pathlib import Path

BASE_URL = (sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1:8008").rstrip("/")
TOKEN = os.environ.get("SOTTOVOCE_TOKEN") or ""
# Bypass HTTP_PROXY from the environment so local or private-network addresses are not routed through a proxy
OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def request(path: str, data: bytes | None = None, content_type: str | None = None) -> tuple[int, str]:
    headers: dict[str, str] = {}
    if TOKEN:
        headers["Authorization"] = f"Bearer {TOKEN}"
    if content_type:
        headers["Content-Type"] = content_type
    req = urllib.request.Request(f"{BASE_URL}{path}", data=data, headers=headers)
    try:
        with OPENER.open(req, timeout=30) as resp:
            return resp.status, resp.read().decode("utf-8", errors="replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", errors="replace")
    except urllib.error.URLError as e:
        return 0, str(e)


def post_multipart(path: str, file_path: Path, **fields: str) -> tuple[int, str]:
    boundary = uuid.uuid4().hex
    parts: list[bytes] = []
    for name, value in fields.items():
        parts.append(
            f'--{boundary}\r\nContent-Disposition: form-data; name="{name}"\r\n\r\n{value}\r\n'.encode()
        )
    parts.append(
        f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="{file_path.name}"\r\n'
        f"Content-Type: application/octet-stream\r\n\r\n".encode()
        + file_path.read_bytes()
        + f"\r\n--{boundary}--\r\n".encode()
    )
    return request(path, b"".join(parts), f"multipart/form-data; boundary={boundary}")


def post_json(path: str, payload: dict) -> tuple[int, str]:
    return request(path, json.dumps(payload).encode(), "application/json")


def parse_sse_content(raw: str) -> str:
    pieces: list[str] = []
    for line in raw.splitlines():
        if not line.startswith("data: ") or line == "data: [DONE]":
            continue
        chunk = json.loads(line[6:])
        pieces.append(chunk["choices"][0]["delta"].get("content") or "")
    return "".join(pieces)


def main() -> int:
    status, body = request("/health")
    try:
        ok = status == 200 and json.loads(body).get("ok") is True
    except json.JSONDecodeError:
        ok = False
    if not ok:
        print(f"server not ready: {BASE_URL}/health")
        return 1

    fail = 0

    def check(name: str, text: str) -> None:
        nonlocal fail
        text = text.strip()
        if text:
            print(f"  ok    {name:<28} {text}")
        else:
            print(f"  FAIL  {name}")
            fail = 1

    with tempfile.TemporaryDirectory() as tmp_dir:
        tmp = Path(tmp_dir)
        aiff, wav, caf = tmp / "a.aiff", tmp / "a.wav", tmp / "a.caf"
        subprocess.run(
            ["say", "-v", "Tingting", "-o", str(aiff), "这是一段用来测试本地语音识别服务的中文句子。"],
            check=True,
        )
        subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEI16@16000", str(aiff), str(wav)], check=True)
        subprocess.run(["afconvert", "-f", "caff", "-d", "opus", str(aiff), str(caf)], check=True)  # iMessage voice message format

        code, text = post_multipart("/v1/audio/transcriptions", wav, response_format="text")
        check("transcriptions wav", text if code == 200 else "")

        code, text = post_multipart(
            "/v1/audio/transcriptions",
            caf,
            response_format="text",
            prompt="以下是普通话的句子。",
            hotwords="语音识别",
        )
        check("transcriptions caf+prompt", text if code == 200 else "")

        b64 = base64.b64encode(wav.read_bytes()).decode()
        code, body = post_json(
            "/v1/chat/completions",
            {"messages": [{"role": "user", "content": [{"type": "input_audio", "input_audio": {"data": b64, "format": "wav"}}]}]},
        )
        check("chat input_audio", json.loads(body)["choices"][0]["message"]["content"] if code == 200 else "")

        code, body = post_json(
            "/v1/chat/completions",
            {
                "stream": True,
                "messages": [{"role": "user", "content": [{"type": "audio_url", "audio_url": {"url": f"data:audio/wav;base64,{b64}"}}]}],
            },
        )
        check("chat audio_url stream", parse_sse_content(body) if code == 200 else "")

    code, _ = post_multipart("/v1/audio/transcriptions", Path(__file__))
    if code == 400:
        print("  ok    bad audio returns 400")
    else:
        print(f"  FAIL  bad audio returns {code}")
        fail = 1

    return fail


if __name__ == "__main__":
    raise SystemExit(main())
