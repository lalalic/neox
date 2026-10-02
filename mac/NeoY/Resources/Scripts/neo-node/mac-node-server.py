#!/usr/bin/env python3
import json
import os
import pathlib
import shutil
import signal
import subprocess
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HOST = os.environ.get("MAC_NODE_HOST", "127.0.0.1")
PORT = int(os.environ.get("MAC_NODE_PORT", "8789"))
NODE_NAME = os.environ.get("MAC_NODE_NAME", "node")
MAX_OUTPUT = 4 * 1024 * 1024
DEFAULT_TIMEOUT = 120
MAX_TIMEOUT = 900
SESSIONS = {}
SESSIONS_LOCK = threading.Lock()

TOOLS = [
    {
        "name": "shell_exec",
        "description": f"Run a shell command on node {NODE_NAME}.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "command": {"type": "string"},
                "cwd": {"type": "string"},
                "timeout_ms": {"type": "integer"},
            },
            "required": ["command"],
        },
    },
    {
        "name": "fs_read",
        "description": f"Read a UTF-8 file on node {NODE_NAME}.",
        "inputSchema": {
            "type": "object",
            "properties": {"path": {"type": "string"}, "max_bytes": {"type": "integer"}},
            "required": ["path"],
        },
    },
    {
        "name": "fs_write",
        "description": f"Write a UTF-8 file on node {NODE_NAME}.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "path": {"type": "string"},
                "content": {"type": "string"},
                "append": {"type": "boolean"},
            },
            "required": ["path", "content"],
        },
    },
    {
        "name": "fs_list",
        "description": f"List a directory on node {NODE_NAME}.",
        "inputSchema": {
            "type": "object",
            "properties": {"path": {"type": "string"}, "limit": {"type": "integer"}},
        },
    },
    {
        "name": "process_list",
        "description": f"List processes on node {NODE_NAME}.",
        "inputSchema": {
            "type": "object",
            "properties": {"query": {"type": "string"}, "limit": {"type": "integer"}},
        },
    },
    {
        "name": "shell_start",
        "description": f"Start a long-running shell command on node {NODE_NAME}.",
        "inputSchema": {
            "type": "object",
            "properties": {"command": {"type": "string"}, "cwd": {"type": "string"}},
            "required": ["command"],
        },
    },
    {
        "name": "shell_poll",
        "description": f"Poll a shell session on node {NODE_NAME}.",
        "inputSchema": {
            "type": "object",
            "properties": {"session_id": {"type": "string"}, "wait_ms": {"type": "integer"}},
            "required": ["session_id"],
        },
    },
]

def resolve_path(value):
    p = pathlib.Path(value or "~").expanduser()
    if not p.is_absolute():
        p = pathlib.Path.home() / p
    return p.resolve()

def shell_exec(args):
    timeout = min(MAX_TIMEOUT, max(1, int(args.get("timeout_ms", DEFAULT_TIMEOUT * 1000) / 1000)))
    proc = subprocess.run(
        [os.environ.get("SHELL", "/bin/zsh"), "-lc", args["command"]],
        cwd=str(resolve_path(args.get("cwd", "~"))),
        capture_output=True,
        text=True,
        timeout=timeout,
        env=os.environ.copy(),
    )
    return {
        "exitCode": proc.returncode,
        "signal": None,
        "timedOut": False,
        "stdout": proc.stdout[-MAX_OUTPUT:],
        "stderr": proc.stderr[-MAX_OUTPUT:],
    }

def fs_read(args):
    p = resolve_path(args["path"])
    max_bytes = min(MAX_OUTPUT, max(1, int(args.get("max_bytes", MAX_OUTPUT))))
    data = p.read_bytes()
    return {
        "path": str(p),
        "size": len(data),
        "truncated": len(data) > max_bytes,
        "content": data[:max_bytes].decode("utf-8", errors="replace"),
    }

def fs_write(args):
    p = resolve_path(args["path"])
    p.parent.mkdir(parents=True, exist_ok=True)
    content = args["content"]
    if args.get("append"):
        with p.open("a", encoding="utf-8") as f:
            f.write(content)
    else:
        tmp = p.with_name(p.name + f".tmp-{os.getpid()}-{uuid.uuid4().hex}")
        tmp.write_text(content, encoding="utf-8")
        os.replace(tmp, p)
    return {"path": str(p), "bytesWritten": len(content.encode()), "append": bool(args.get("append"))}

def fs_list(args):
    p = resolve_path(args.get("path", "~"))
    limit = min(2000, max(1, int(args.get("limit", 500))))
    entries = []
    for child in list(p.iterdir())[:limit]:
        try:
            st = child.lstat()
            kind = "directory" if child.is_dir() else "file" if child.is_file() else "symlink" if child.is_symlink() else "other"
            entries.append({"name": child.name, "type": kind, "size": st.st_size if kind == "file" else None})
        except OSError:
            pass
    return {"path": str(p), "entries": entries, "truncated": len(entries) >= limit}

def process_list(args):
    proc = subprocess.run(["/bin/ps", "-axo", "pid=,ppid=,user=,stat=,%cpu=,%mem=,etime=,command="], capture_output=True, text=True)
    query = str(args.get("query", "")).lower()
    limit = min(1000, max(1, int(args.get("limit", 200))))
    rows = []
    for line in proc.stdout.splitlines():
        if query and query not in line.lower():
            continue
        rows.append(line.strip())
        if len(rows) >= limit:
            break
    return {"processes": rows, "truncated": len(rows) >= limit}

def shell_start(args):
    cwd = str(resolve_path(args.get("cwd", "~")))
    proc = subprocess.Popen(
        [os.environ.get("SHELL", "/bin/zsh"), "-lc", args["command"]],
        cwd=cwd,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        env=os.environ.copy(),
    )
    sid = str(uuid.uuid4())
    with SESSIONS_LOCK:
        SESSIONS[sid] = {"proc": proc, "cwd": cwd, "command": args["command"], "startedAt": time.time()}
    return {"session_id": sid, "pid": proc.pid, "command": args["command"], "cwd": cwd}

def shell_poll(args):
    sid = args["session_id"]
    with SESSIONS_LOCK:
        item = SESSIONS.get(sid)
    if not item:
        raise ValueError(f"unknown shell session: {sid}")
    proc = item["proc"]
    wait_ms = min(30000, max(0, int(args.get("wait_ms", 0))))
    if proc.poll() is None and wait_ms:
        try:
            proc.wait(timeout=wait_ms / 1000)
        except subprocess.TimeoutExpired:
            pass
    if proc.poll() is None:
        return {"session_id": sid, "running": True, "pid": proc.pid, "stdout": "", "stderr": ""}
    stdout, stderr = proc.communicate()
    with SESSIONS_LOCK:
        SESSIONS.pop(sid, None)
    return {
        "session_id": sid,
        "running": False,
        "pid": proc.pid,
        "exitCode": proc.returncode,
        "stdout": stdout[-MAX_OUTPUT:],
        "stderr": stderr[-MAX_OUTPUT:],
    }

HANDLERS = {
    "shell_exec": shell_exec,
    "fs_read": fs_read,
    "fs_write": fs_write,
    "fs_list": fs_list,
    "process_list": process_list,
    "shell_start": shell_start,
    "shell_poll": shell_poll,
}

class Handler(BaseHTTPRequestHandler):
    server_version = "NeoMacNode/1.0"

    def log_message(self, fmt, *args):
        print(f"[{NODE_NAME}] {self.address_string()} {fmt % args}", flush=True)

    def send_json(self, status, body, session_id=None):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        if session_id:
            self.send_header("Mcp-Session-Id", session_id)
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path == "/healthz":
            body = f"ok {NODE_NAME}\n".encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        self.send_error(404)

    def do_POST(self):
        if self.path != "/mcp":
            self.send_error(404)
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
            msg = json.loads(self.rfile.read(length))
            method = msg.get("method")
            rid = msg.get("id")
            sid = self.headers.get("Mcp-Session-Id")
            if method == "initialize":
                sid = str(uuid.uuid4())
                result = {
                    "protocolVersion": "2025-06-18",
                    "capabilities": {"tools": {}},
                    "serverInfo": {"name": f"{NODE_NAME}-mac-tools", "version": "1.0.0"},
                }
                self.send_json(200, {"jsonrpc": "2.0", "id": rid, "result": result}, sid)
            elif method == "notifications/initialized":
                self.send_json(202, {})
            elif method == "tools/list":
                self.send_json(200, {"jsonrpc": "2.0", "id": rid, "result": {"tools": TOOLS}}, sid)
            elif method == "tools/call":
                params = msg.get("params") or {}
                name = params.get("name")
                fn = HANDLERS.get(name)
                if not fn:
                    raise ValueError(f"unknown tool: {name}")
                value = fn(params.get("arguments") or {})
                result = {"content": [{"type": "text", "text": json.dumps(value, indent=2)}], "isError": False}
                self.send_json(200, {"jsonrpc": "2.0", "id": rid, "result": result}, sid)
            else:
                self.send_json(200, {"jsonrpc": "2.0", "id": rid, "error": {"code": -32601, "message": "Method not found"}}, sid)
        except Exception as e:
            self.send_json(500, {"jsonrpc": "2.0", "id": None, "error": {"code": -32000, "message": str(e)}})

if __name__ == "__main__":
    print(f"[{NODE_NAME}] MCP http://{HOST}:{PORT}/mcp", flush=True)
    print(f"[{NODE_NAME}] health http://{HOST}:{PORT}/healthz", flush=True)
    ThreadingHTTPServer((HOST, PORT), Handler).serve_forever()
