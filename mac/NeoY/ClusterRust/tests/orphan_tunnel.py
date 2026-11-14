#!/usr/bin/env python3
"""Reap only the predecessor's owned SSH tunnel after an ungraceful node crash."""
import os,signal,subprocess,tempfile,time,socket
from pathlib import Path
from urllib.request import urlopen
import sys
BINARY=Path(sys.argv[1] if len(sys.argv)>1 else Path(__file__).parents[1]/'target/debug/neo-cluster-rust').resolve()
with tempfile.TemporaryDirectory(prefix='neo-cluster-orphan-') as d:
    root=Path(d)
    with socket.socket() as s:s.bind(('127.0.0.1',0));port=s.getsockname()[1]
    ssh=root/'fake-ssh'
    ssh.write_text('#!/bin/sh\nwhile :; do /bin/sleep 1; done\n');ssh.chmod(0o755)
    conf=root/'node.env'
    conf.write_text(f'NODE_NAME=orphan-test\nNODE_ROOT={root}\nNODE_MODE=session\nLOCAL_MCP_PORT={port}\nHUB_SSH_TARGET=orphan@example.invalid\nHUB_MCP_PORT=29112\nSSH_BIN={ssh}\n')
    env=dict(os.environ,NEO_NODE_CONFIG=str(conf))
    processes=[]
    def running(pid):
        try:os.kill(pid,0);return True
        except ProcessLookupError:return False
    def health():
        try:
            with urlopen(f'http://127.0.0.1:{port}/healthz',timeout=1) as req:return req.status==200
        except Exception:return False
    def await_pid(timeout=7):
        for _ in range(timeout*20):
            if (root/'run/tunnel.pid').is_file() and health():
                pid=int((root/'run/tunnel.pid').read_text())
                if running(pid):return pid
            time.sleep(.05)
        raise AssertionError('did not launch SSH tunnel')
    try:
        first=subprocess.Popen([str(BINARY),'run'],env=env,stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        processes.append(first)
        old_pid=await_pid()
        os.kill(first.pid,signal.SIGKILL);first.wait(timeout=5)
        assert running(old_pid),'test setup did not preserve orphan SSH process'
        second=subprocess.Popen([str(BINARY),'run'],env=env,stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        processes.append(second)
        new_pid=await_pid()
        assert old_pid!=new_pid,(old_pid,new_pid)
        for _ in range(50):
            if not running(old_pid):break
            # The old process may be a zombie until reaped by launchd; ps should
            # no longer show a non-zombie SSH listener after cleanup.
            report=subprocess.run(['/bin/ps','-p',str(old_pid),'-o','stat='],capture_output=True,text=True)
            if report.returncode!=0 or report.stdout.strip().startswith('Z'):break
            time.sleep(.05)
        status=subprocess.run(['/bin/ps','-p',str(old_pid),'-o','stat='],capture_output=True,text=True)
        assert status.returncode!=0 or status.stdout.strip().startswith('Z'),f'old tunnel still running: {status.stdout}'
        assert health() and running(new_pid)
        print(f'PASS orphan SSH tunnel {old_pid} replaced by {new_pid} after node SIGKILL',flush=True)
    finally:
        for proc in processes:
            if proc.poll() is None:proc.terminate()
            try:proc.wait(timeout=5)
            except subprocess.TimeoutExpired:proc.kill();proc.wait()
        p=root/'run/tunnel.pid'
        if p.exists():
            pid=int(p.read_text())
            try:os.kill(pid,signal.SIGKILL)
            except ProcessLookupError:pass
