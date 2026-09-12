#!/usr/bin/env python3
"""Small reference Neoy bridge for the phone-facing POST /agent contract."""
from __future__ import annotations

import argparse
import http.server
import pathlib
import queue
import threading


class BridgeHandler(http.server.BaseHTTPRequestHandler):
    inbox: queue.Queue[str] = queue.Queue()

    def do_POST(self) -> None:  # noqa: N802
        if self.path != "/agent":
            self.send_error(404)
            return
        length = int(self.headers.get("Content-Length", "0"))
        message = self.rfile.read(length).decode("utf-8")
        self.inbox.put(message)
        self.send_response(200)
        self.end_headers()

    def log_message(self, *_args: object) -> None:
        pass


def main() -> None:
    parser = argparse.ArgumentParser(description="LAN-only Neoy reference bridge")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--queue-dir", type=pathlib.Path)
    args = parser.parse_args()
    server = http.server.ThreadingHTTPServer((args.host, args.port), BridgeHandler)
    print(f"Neoy listening on http://{args.host}:{args.port}/agent")

    def persist() -> None:
        while True:
            message = BridgeHandler.inbox.get()
            if args.queue_dir:
                args.queue_dir.mkdir(parents=True, exist_ok=True)
                path = args.queue_dir / f"handoff-{threading.get_native_id()}-{BridgeHandler.inbox.qsize()}.txt"
                path.write_text(message, encoding="utf-8")
            else:
                print(message, flush=True)

    threading.Thread(target=persist, daemon=True).start()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
