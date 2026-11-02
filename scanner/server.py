"""Local HTTP boundary around LLM Guard's prompt-injection scanner.

Binds to loopback by default (a container sets AGENTGATE_SCANNER_HOST so other containers on
its private network can reach it) and returns scores, never the scanned text. All policy
(what to block, quarantine, and log) stays in the Node controller.
"""

import json
import os
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from llm_guard.input_scanners import PromptInjection
from llm_guard.input_scanners.prompt_injection import MatchType

HOST = os.environ.get("AGENTGATE_SCANNER_HOST", "127.0.0.1")
PORT = int(os.environ.get("AGENTGATE_SCANNER_PORT", "8765"))
THRESHOLD = float(os.environ.get("AGENTGATE_SCANNER_THRESHOLD", "0.9"))
MAX_BODY_BYTES = 512 * 1024
MAX_TEXTS = 64
MAX_TEXT_CHARS = 32_000

# CHUNKS scans the whole text, so an injection placed after the model's
# 512-token window is still seen.
scanner = PromptInjection(threshold=THRESHOLD, match_type=MatchType.CHUNKS)
scan_lock = threading.Lock()


class Handler(BaseHTTPRequestHandler):
    server_version = "agentgate-scanner"

    def log_message(self, format, *args):  # noqa: A002 - signature fixed by the base class
        return  # request lines carry no text, but keep the console quiet and private

    def _send(self, status, payload):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/health":
            self._send(200, {"status": "ok", "scanner": "llm-guard/PromptInjection"})
        else:
            self._send(404, {"error": "not found"})

    def do_POST(self):
        if self.path != "/scan":
            return self._send(404, {"error": "not found"})
        length = int(self.headers.get("content-length", "0"))
        if length <= 0 or length > MAX_BODY_BYTES:
            return self._send(413, {"error": "invalid body size"})
        try:
            texts = json.loads(self.rfile.read(length)).get("texts")
        except (ValueError, AttributeError):
            return self._send(400, {"error": "invalid json"})
        if (
            not isinstance(texts, list)
            or not 0 < len(texts) <= MAX_TEXTS
            or not all(isinstance(t, str) and len(t) <= MAX_TEXT_CHARS for t in texts)
        ):
            return self._send(400, {"error": "invalid texts"})
        results = []
        with scan_lock:
            for text in texts:
                _, valid, score = scanner.scan(text)
                results.append({"valid": bool(valid), "score": float(score)})
        self._send(200, {"scanner": "llm-guard/PromptInjection", "results": results})


if __name__ == "__main__":
    print(f"AGENTGATE scanner ready on http://{HOST}:{PORT}", flush=True)
    ThreadingHTTPServer((HOST, PORT), Handler).serve_forever()
