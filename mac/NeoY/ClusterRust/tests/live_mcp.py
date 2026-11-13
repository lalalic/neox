#!/usr/bin/env python3
"""Isolated real HTTP/MCP and launch lifecycle smoke test of neo-cluster-rust.

No SSH credentials, global launchd entries, or user files are touched. The
binary is launched in a temporary session-mode node on an ephemeral port.
"""
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import tempfile
import time
from urllib.error import HTTPError
from urllib.request import Request, urlopen

BINARY = Path(sys.argv[1] if len(sys.argv)>1 else Path(__file__).parents[1]/'target/debug/neo-cluster-rust').resolve()
assert BINARY.is_file(), BINARY
with tempfile.TemporaryDirectory(prefix='neo-cluster-rust-e2e-') as root:
    root = Path(root)
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0)); port=sock.getsockname()[1]
    config = root/'node.env'
    config.write_text(f'NODE_NAME=isolated-rust-test\nNODE_MODE=session\nNODE_ROOT={root}\nLOCAL_MCP_PORT={port}\nHUB_SSH_TARGET=\n')
    # Simulate the SSH bootstrap's staged binary without modifying ~/.local/bin.
    (root/'neo-cluster-rust').symlink_to(BINARY)
    env = dict(os.environ, NEO_NODE_CONFIG=str(config))
    url=f'http://127.0.0.1:{port}'
    def request(method, params=None):
        data=json.dumps(dict(jsonrpc='2.0',id=1,method=method,params=params or {})).encode()
        with urlopen(Request(url+'/mcp',data=data,headers={'Content-Type':'application/json'}),timeout=8) as resp:
            return resp.status,json.load(resp)
    def tool(name,**args):
        status,answer=request('tools/call',{'name':name,'arguments':args})
        assert status==200 and not answer.get('error'),(name,answer)
        return json.loads(answer['result']['content'][0]['text'])
    def ready():
        try:
            with urlopen(url+'/healthz', timeout=1) as resp:
                return resp.status==200 and resp.read()==b'ok isolated-rust-test\n'
        except Exception:return False
    print('test_binary',str(BINARY),flush=True)
    launched=subprocess.run([str(BINARY),'start'],env=env,capture_output=True,text=True,timeout=15)
    assert launched.returncode==0,(launched.stdout,launched.stderr)
    assert ready(), 'MCP health did not start'
    try:
        status,init=request('initialize');assert status==200 and init['result']['protocolVersion']=='2025-06-18'
        status,list_reply=request('tools/list');assert status==200
        names={v['name'] for v in list_reply['result']['tools']}
        assert names=={'shell_exec','shell_start','shell_poll','fs_read','fs_write','fs_list','process_list'},names
        print('PASS initialize, 7 tools',flush=True)
        exec_result=tool('shell_exec',command='printf out; printf err >&2; exit 7')
        assert (exec_result['exitCode'],exec_result['stdout'],exec_result['stderr'])==(7,'out','err'),exec_result
        timeout=tool('shell_exec',command='sleep 8',timeout_ms=1000)
        assert timeout['timedOut'] is True,timeout
        print('PASS shell exit/stdout/stderr + real timeout',flush=True)
        file=root/'sandbox'/'test.txt'
        write=tool('fs_write',path=str(file),content='hello')
        assert write['bytesWritten']==5
        tool('fs_write',path=str(file),content='-append',append=True)
        read=tool('fs_read',path=str(file))
        assert read['content']=='hello-append',read
        listing=tool('fs_list',path=str(file.parent))
        assert any(item['name']=='test.txt' for item in listing['entries'])
        processes=tool('process_list',query='neo-cluster-rust')
        assert isinstance(processes['processes'],list)
        print('PASS fs_write/read/append/list + process_list',flush=True)
        started=tool('shell_start',command='sleep 0.25; printf async-output')
        sid=started['session_id']
        polled=tool('shell_poll',session_id=sid,wait_ms=2800)
        assert polled['running'] is False and polled['stdout']=='async-output',polled
        print('PASS async shell start/poll',flush=True)
        status_result=subprocess.run([str(BINARY),'status'],env=env,capture_output=True,text=True,timeout=6)
        assert status_result.returncode==0 and 'local MCP: healthy' in status_result.stdout,status_result.stdout
        print('PASS status health',flush=True)
    finally:
        subprocess.run([str(BINARY),'stop'],env=env,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=6)
        for _ in range(35):
            if not ready():break
            time.sleep(.1)
        assert not ready(),'stop failed to close MCP port'
        print('PASS stop releases MCP port',flush=True)
    restarted=subprocess.run([str(BINARY),'start'],env=env,capture_output=True,text=True,timeout=15)
    assert restarted.returncode==0 and ready(),(restarted.stdout,restarted.stderr)
    subprocess.run([str(BINARY),'stop'],env=env,check=True,timeout=6)
    print('PASS restart from stopped state; all MCP and lifecycle checks passed',flush=True)
