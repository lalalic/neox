#!/usr/bin/env python3
"""LAN-only Neoy handoff bridge for the local Neo/Vlog producer."""
import os
import socket
import socketserver
import subprocess
import time
from http.server import BaseHTTPRequestHandler
from pathlib import Path
from urllib.parse import parse_qs, urlparse

PORT = 8686
INBOX = Path.home() / ".neoy" / "inbox"
INBOX.mkdir(parents=True, exist_ok=True)


def pending():
    return sorted(INBOX.glob("*.txt"))


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        if urlparse(self.path).path != "/agent":
            self.send_error(404)
            return
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length)
        if len(body) >= 8:  # Small requests are health checks, not handoffs.
            (INBOX / f"{time.time_ns()}.txt").write_bytes(body)
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"ok")

    def do_GET(self):
        parsed = urlparse(self.path)
        if parsed.path not in {"/agent/next", "/agent/peek"}:
            self.send_error(404)
            return
        try:
            timeout = min(max(float(parse_qs(parsed.query).get("timeout", ["0"])[0]), 0), 30)
        except ValueError:
            self.send_error(400, "timeout must be numeric")
            return
        deadline = time.monotonic() + timeout
        while True:
            files = pending()
            if files:
                message = files[0].read_bytes()
                if parsed.path == "/agent/next":
                    files[0].unlink()
                self.send_response(200)
                self.send_header("Content-Type", "text/plain; charset=utf-8")
                self.send_header("Content-Length", str(len(message)))
                self.end_headers()
                self.wfile.write(message)
                return
            if time.monotonic() >= deadline:
                self.send_response(204)
                self.end_headers()
                return
            time.sleep(0.25)

    def log_message(self, *_args):
        pass


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


host = socket.gethostname().split(".")[0]
try:
    probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    probe.connect(("8.8.8.8", 80))
    ip = probe.getsockname()[0]
    probe.close()
except OSError:
    ip = "127.0.0.1"

subprocess.Popen(
    ["dns-sd", "-R", host, "_neoy._tcp", ".", str(PORT),
     "path=/agent", f"host={host}", f"port={PORT}", f"ip={ip}"],
    stdout=subprocess.DEVNULL,
    stderr=subprocess.DEVNULL,
)
Server(("0.0.0.0", PORT), Handler).serve_forever()
