#!/usr/bin/env python3
"""CLI start must not report success before a reverse SSH tunnel survives startup."""
import os,socket,subprocess,sys,tempfile
from pathlib import Path
BINARY=Path(sys.argv[1] if len(sys.argv)>1 else Path(__file__).parents[1]/'target/debug/neo-cluster-rust').resolve()
with tempfile.TemporaryDirectory(prefix='neo-cluster-not-ready-') as d:
    root=Path(d)
    with socket.socket() as s:s.bind(('127.0.0.1',0));port=s.getsockname()[1]
    ssh=root/'fake-ssh';ssh.write_text('#!/bin/sh\nexit 9\n');ssh.chmod(0o755)
    cfg=root/'node.env';cfg.write_text(f'NODE_NAME=tunnel-not-ready\nNODE_ROOT={root}\nNODE_MODE=session\nLOCAL_MCP_PORT={port}\nHUB_SSH_TARGET=user@example.invalid\nHUB_MCP_PORT=28901\nSSH_BIN={ssh}\n')
    (root/'neo-cluster-rust').symlink_to(BINARY)
    env=dict(os.environ,NEO_NODE_CONFIG=str(cfg))
    try:
        result=subprocess.run([str(BINARY),'start'],env=env,timeout=16,capture_output=True,text=True)
        assert result.returncode!=0 and 'did not become healthy' in result.stderr,(result.returncode,result.stderr)
        assert not (root/'run/tunnel.ready').exists(), 'failed SSH falsely reported ready'
        print('PASS failed SSH tunnel never reports ready',flush=True)
    finally:
        subprocess.run([str(BINARY),'stop'],env=env,timeout=8,capture_output=True)
