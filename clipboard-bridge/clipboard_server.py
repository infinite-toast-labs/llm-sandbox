#!/usr/bin/env python3
"""
clipboard_server.py — Tiny HTTP clipboard bridge for tmux → browser → system clipboard.

This server acts as a relay: tmux's copy-pipe writes clipboard text here via HTTP POST,
and the browser-side JavaScript polls via HTTP GET, then writes to the system clipboard
using the Clipboard API.

Listens on 127.0.0.1:9123 (container-internal only, exposed via nginx reverse proxy).

Endpoints:
  POST /   — Store clipboard text (from ~/clip script, called by tmux copy-pipe)
  GET  /   — Retrieve and clear stored clipboard text (called by browser JS poller)

The GET is destructive (clears after read) to avoid re-writing the same text on every poll.
"""
from http.server import HTTPServer, BaseHTTPRequestHandler
import threading

_clip = ""
_lock = threading.Lock()
_version = 0


class ClipboardHandler(BaseHTTPRequestHandler):

    def do_POST(self):
        """Store clipboard text sent by the ~/clip script."""
        global _clip, _version
        n = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(n).decode("utf-8") if n else ""
        with _lock:
            _clip = body
            _version += 1
        self.send_response(200)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(b"ok")

    def do_GET(self):
        """Return stored clipboard text (clears after read)."""
        global _clip
        with _lock:
            data = _clip
            _clip = ""  # Clear after reading to avoid duplicate writes
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(data.encode("utf-8"))

    def do_OPTIONS(self):
        """Handle CORS preflight requests."""
        self.send_response(200)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.end_headers()

    def log_message(self, *a):
        """Suppress request logging to keep container logs clean."""
        pass


if __name__ == "__main__":
    HTTPServer(("127.0.0.1", 9123), ClipboardHandler).serve_forever()
