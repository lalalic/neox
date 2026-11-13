#!/usr/bin/env python3
"""Detached native supervisor restarts an SSH child after unexpected termination."""
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time
from urllib.request import urlopen

BINARY=Path(sys.argv[1] if len(sys.argv)>1 else Path(__file__).parents[1]/'target/debug/neo-cluster-rust').resolve()
with tempfile.TemporaryDirectory(prefix='neo-cluster-rust-tunnel-') as root:
    root=Path(root)
    with socket.socket() as sock:
        sock.bind(('127.0.0.1',0));port=sock.getsockname()[1]
    calls=root/'ssh-calls'; ssh=root/'fake-ssh'
    ssh.write_text(f'#!/bin/sh\necho call >> {calls}\nsleep .2\nexit 9\n')
    ssh.chmod(0o755)
    config=root/'node.env'
    config.write_text(f'NODE_NAME=ssh-e2e\nNODE_MODE=session\nNODE_ROOT={root}\nLOCAL_MCP_PORT={port}\nHUB_SSH_TARGET=test@example.invalid\nHUB_MCP_PORT=28785\nSSH_BIN={ssh}\n')
    env=dict(os.environ, NEO_NODE_CONFIG=str(config))
    proc=subprocess.Popen([str(BINARY),'run'],env=env,stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    try:
        for _ in range(60):
            if calls.exists() and len(calls.read_text().splitlines())>=2:break
            time.sleep(.1)
        assert calls.exists() and len(calls.read_text().splitlines())>=2,'tunnel was not relaunched after failure'
        with urlopen(f'http://127.0.0.1:{port}/healthz',timeout=3) as r:assert r.status==200
        print('PASS SSH child restarted after failure; MCP remained healthy',flush=True)
    finally:
        proc.terminate();proc.wait(timeout=7)
    assert not (root/'run/supervisor.pid').exists(),'stale supervisor.pid'
    print('PASS clean shutdown removed run-state PID',flush=True)
