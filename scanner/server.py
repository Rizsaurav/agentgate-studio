"""Local HTTP boundary around LLM Guard's prompt-injection scanner.

Binds to loopback by default (a container sets AGENTGATE_SCANNER_HOST so other containers on
its private network can reach it) and returns scores, never the scanned text. All policy
(what to block, quarantine, and log) stays in the Node controller.
"""

import json
import os
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import retrieval
from llm_guard.input_scanners import PromptInjection
from llm_guard.input_scanners.prompt_injection import MatchType

HOST = os.environ.get("AGENTGATE_SCANNER_HOST", "127.0.0.1")
PORT = int(os.environ.get("AGENTGATE_SCANNER_PORT", "8765"))
THRESHOLD = float(os.environ.get("AGENTGATE_SCANNER_THRESHOLD", "0.9"))
MAX_BODY_BYTES = 512 * 1024
MAX_TEXTS = 64
MAX_TEXT_CHARS = 32_000

# One model, two ways of reading text. "chunks" splits long text into windows so an injection placed
# after the model's 512-token window is still seen; "full" reads text that already fits one window
# as a whole, which avoids the false positives that splitting ordinary instructions into pieces causes.
scanner = PromptInjection(threshold=THRESHOLD, match_type=MatchType.CHUNKS)
MODES = {"chunks": MatchType.CHUNKS, "full": MatchType.FULL}
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
            self._send(200, {"status": "ok", "scanner": "llm-guard/PromptInjection", "retrieval": retrieval.models()})
        else:
            self._send(404, {"error": "not found"})

    def _texts(self, value):
        return (
            isinstance(value, list)
            and 0 < len(value) <= MAX_TEXTS
            and all(isinstance(t, str) and len(t) <= MAX_TEXT_CHARS for t in value)
        )

    def _retrieval(self, payload):
        """Embeddings, reranking and entailment: numbers only, the same size limits as scanning."""
        if self.path == "/embed":
            texts = payload.get("texts")
            if not self._texts(texts):
                return self._send(400, {"error": "invalid texts"})
            return self._send(200, {"vectors": retrieval.embed(texts, query=payload.get("query") is True)})
        if self.path == "/rerank":
            query, texts = payload.get("query"), payload.get("texts")
            if not isinstance(query, str) or not 0 < len(query) <= MAX_TEXT_CHARS or not self._texts(texts):
                return self._send(400, {"error": "invalid query or texts"})
            return self._send(200, {"scores": retrieval.rerank(query, texts)})
        pairs = payload.get("pairs")
        if (
            not isinstance(pairs, list)
            or not 0 < len(pairs) <= MAX_TEXTS
            or not all(
                isinstance(pair, dict)
                and isinstance(pair.get("premise"), str)
                and isinstance(pair.get("hypothesis"), str)
                and len(pair["premise"]) <= MAX_TEXT_CHARS
                and len(pair["hypothesis"]) <= MAX_TEXT_CHARS
                for pair in pairs
            )
        ):
            return self._send(400, {"error": "invalid pairs"})
        return self._send(200, {"results": retrieval.entail([(p["premise"], p["hypothesis"]) for p in pairs])})

    def do_POST(self):
        if self.path not in ("/scan", "/embed", "/rerank", "/entail"):
            return self._send(404, {"error": "not found"})
        length = int(self.headers.get("content-length", "0"))
        if length <= 0 or length > MAX_BODY_BYTES:
            return self._send(413, {"error": "invalid body size"})
        try:
            payload = json.loads(self.rfile.read(length))
            if not isinstance(payload, dict):
                raise ValueError
        except ValueError:
            return self._send(400, {"error": "invalid json"})
        if self.path != "/scan":
            return self._retrieval(payload)
        try:
            texts = payload.get("texts")
            mode = payload.get("mode", "chunks")
        except (ValueError, AttributeError):
            return self._send(400, {"error": "invalid json"})
        if not isinstance(mode, str) or mode not in MODES:
            return self._send(400, {"error": "invalid mode"})
        if (
            not isinstance(texts, list)
            or not 0 < len(texts) <= MAX_TEXTS
            or not all(isinstance(t, str) and len(t) <= MAX_TEXT_CHARS for t in texts)
        ):
            return self._send(400, {"error": "invalid texts"})
        results = []
        with scan_lock:
            # The match type is read per scan and the lock serialises requests, so setting it here is safe.
            scanner._match_type = MODES[mode]
            for text in texts:
                _, valid, score = scanner.scan(text)
                results.append({"valid": bool(valid), "score": float(score)})
        self._send(200, {"scanner": "llm-guard/PromptInjection", "results": results})


if __name__ == "__main__":
    # Retrieval models are loaded before serving, inside the health check's start period, so the first question
    # does not time out while they download. AGENTGATE_RETRIEVAL_PRELOAD=0 loads them on first use instead.
    if os.environ.get("AGENTGATE_RETRIEVAL_PRELOAD", "1") != "0":
        print("Loading retrieval models...", flush=True)
        retrieval.preload()
    print(f"AGENTGATE scanner ready on http://{HOST}:{PORT}", flush=True)
    ThreadingHTTPServer((HOST, PORT), Handler).serve_forever()
