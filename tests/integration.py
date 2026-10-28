"""Run isolated Neovim tests against a local, GET-only OpenCode fixture."""

import base64
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import time
from urllib.parse import parse_qs, urlsplit


ROOT = Path(__file__).resolve().parents[1]
PASSWORD = "fixture-password"
AUTH = "Basic " + base64.b64encode(f"opencode:{PASSWORD}".encode()).decode()
requests = []
refreshes = 0
context_reads = {}


def session(identifier):
    return {"id": identifier, "title": "Plan " + identifier, "location": {"directory": str(ROOT)}}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        global refreshes
        url = urlsplit(self.path)
        query = parse_qs(url.query)
        requests.append((url.path, query))
        if self.headers.get("Authorization") != AUTH:
            return self.respond(401, {"error": "Unauthorized"})
        if url.path == "/api/model":
            assert "location[directory]" in query
            directory = query["location[directory]"][0]
            if directory.endswith("/no-models"):
                return self.respond(200, {"data": []})
            if directory.endswith("/bad-models"):
                return self.respond(200, {"data": [None]})
            return self.respond(200, {"data": [
                {
                    "providerID": "fixture", "id": "fast-alias", "modelID": "actual-provider-model",
                    "name": "Fast model", "enabled": True,
                    "capabilities": {"input": ["text"], "output": ["text"]},
                    "headers": {"Authorization": "PRIVATE_MODEL_HEADER"},
                    "variants": [{"id": "none", "body": {"private": "PRIVATE_VARIANT_BODY"}}, {"id": "high"}],
                },
                {
                    "providerID": "other", "id": "vendor/basic", "name": "Basic model", "enabled": True,
                    "capabilities": {"input": ["text"], "output": ["text"]}, "variants": [],
                },
                {"providerID": "fixture", "id": "disabled", "enabled": False},
                {
                    "providerID": "fixture", "id": "image", "enabled": True,
                    "capabilities": {"input": ["text"], "output": ["image"]}, "variants": [],
                },
                {"providerID": "fixture", "id": "non-chat", "type": "decision", "enabled": True},
            ]})
        if url.path == "/api/session":
            if "cursor" in query:
                assert query["cursor"] == ["page 2/α"]
                assert "order" not in query
                return self.respond(200, {"data": [session("ses_B")], "cursor": {"next": None}})
            return self.respond(200, {"data": [session("ses_A")], "cursor": {"next": "page 2/α"}})
        if url.path == "/repeat":
            return self.respond(200, {"data": [], "cursor": {"next": "same"}})
        if url.path == "/invalid":
            return self.respond(200, {"wrong": "shape"})
        if url.path == "/missing-cursor":
            return self.respond(200, {"data": []})
        if url.path == "/timeout":
            time.sleep(0.4)
            return self.respond(200, {"data": {}})
        parts = url.path.split("/")
        if len(parts) >= 4 and parts[1:3] == ["api", "session"]:
            identifier = parts[3]
            if len(parts) == 4:
                return self.respond(200, {"data": session(identifier)})
            if parts[4] == "message":
                assert query.get("type") == ["compaction"]
                return self.respond(200, {"data": [{
                    "id": "msg_checkpoint", "type": "compaction", "status": "completed",
                    "summary": "Keep the existing architecture.",
                }], "cursor": {"next": None}})
            if parts[4] == "context":
                context_reads[identifier] = context_reads.get(identifier, 0) + 1
                if identifier == "ses_Error":
                    return self.respond(503, {"error": "Fixture unavailable"})
                if identifier == "ses_Flaky" and context_reads[identifier] > 1:
                    return self.respond(503, {"error": "Fixture unavailable"})
                if identifier == "ses_Malformed":
                    return self.respond(200, {"data": [None]})
                if identifier == "ses_Slow":
                    time.sleep(0.25)
                if identifier == "ses_Large":
                    return self.respond(200, {"data": [{"type": "user", "text": "αβ " * 150000}]})
                if identifier == "ses_Checkpoint":
                    return self.respond(200, {"data": [{
                        "type": "compaction", "status": "completed", "summary": "Already included.",
                    }]})
                refreshes += 1
                return self.respond(200, {"data": [
                    {"type": "user", "text": f"Decision {refreshes}: use the parser αβ."},
                    {"type": "assistant", "content": [
                        {"type": "text", "text": "Preserve error handling."},
                        {"type": "reasoning", "text": "PRIVATE_REASONING_MARKER"},
                        {"type": "tool", "name": "webfetch", "state": {
                            "status": "completed", "input": {"url": "https://example.test/docs"},
                            "content": [{"type": "text", "text": "The documented API."}],
                        }},
                    ]},
                ]})
        return self.respond(404, {"error": "Unknown fixture route"})

    def respond(self, status, body):
        data = json.dumps(body, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        try:
            self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError):
            pass


if __name__ == "__main__":
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        with tempfile.TemporaryDirectory(prefix="open-compleat-tests-", dir="/tmp/opencode") as scratch:
            url = f"http://127.0.0.1:{server.server_port}"
            registration = Path(scratch) / "service.json"
            registration.write_text(json.dumps({"url": url, "password": PASSWORD, "version": "2.1.4"}))
            registration.chmod(0o600)
            result = subprocess.run(
                ["nvim", "--headless", "-u", "NONE", "-i", "NONE", "-n", "-l", "tests/run.lua"],
                cwd=ROOT,
                env=os.environ | {"OC_TEST_SERVICE": str(registration), "OC_TEST_URL": url, "OC_TEST_SCRATCH": scratch},
                timeout=35,
            )
            assert result.returncode == 0, f"Neovim tests exited {result.returncode}"
            assert any(path == "/api/session" and "directory" in query for path, query in requests)
            assert any(path == "/api/session" and "directory" not in query for path, query in requests)
            print(f"PASS: {len(requests)} authenticated GET requests; no generation or mutation routes")
    finally:
        server.shutdown()
        server.server_close()
