#!/usr/bin/env python3
"""Real MCP cancellation at service shutdown must terminate both process groups."""
import json, os, socket, subprocess, sys, tempfile, threading, time
from pathlib import Path
from urllib.request import Request,urlopen
from urllib.error import URLError,HTTPError
BINARY=Path(sys.argv[1] if len(sys.argv)>1 else Path(__file__).parents[1]/'target/debug/neo-cluster-rust').resolve()
with tempfile.TemporaryDirectory(prefix='cluster-shutdown-') as d:
    root=Path(d)
    with socket.socket() as sock: sock.bind(('127.0.0.1',0));port=sock.getsockname()[1]
    cfg=root/'node.env';cfg.write_text(f'NODE_NAME=shutdown-test\nNODE_MODE=session\nNODE_ROOT={root}\nLOCAL_MCP_PORT={port}\nHUB_SSH_TARGET=\n')
    (root/'neo-cluster-rust').symlink_to(BINARY)
    env=dict(os.environ,NEO_NODE_CONFIG=str(cfg))
    started=subprocess.run([str(BINARY),'start'],env=env,capture_output=True,text=True,timeout=12)
    assert started.returncode==0,(started.stdout,started.stderr)
    def tool(name,args):
        request=json.dumps({'jsonrpc':'2.0','id':1,'method':'tools/call','params':{'name':name,'arguments':args}}).encode()
        with urlopen(Request(f'http://127.0.0.1:{port}/mcp',data=request,headers={'Content-Type':'application/json'}),timeout=35) as resp:
            data=json.load(resp)
            return json.loads(data['result']['content'][0]['text'])
    def group_exists(pid):
        try:os.kill(-pid,0);return True
        except ProcessLookupError:return False
    try:
        async_pidfile=root/'async.pid';sync_pidfile=root/'sync.pid'
        a=tool('shell_start',{'command':f'echo $$ > {async_pidfile}; exec sleep 40'})
        error=[]
        def long_exec():
            try:tool('shell_exec',{'command':f'echo $$ > {sync_pidfile}; exec sleep 40','timeout_ms':90000})
            except (URLError,HTTPError,ConnectionError,TimeoutError):pass
            except Exception as e:error.append(e)
        thread=threading.Thread(target=long_exec,daemon=True);thread.start()
        for _ in range(90):
            if async_pidfile.exists() and sync_pidfile.exists():break
            time.sleep(.05)
        assert async_pidfile.exists() and sync_pidfile.exists(), 'shell execution did not begin'
        pids=[int(async_pidfile.read_text()),int(sync_pidfile.read_text())]
        assert all(group_exists(pid) for pid in pids)
        stopped=subprocess.run([str(BINARY),'stop'],env=env,capture_output=True,text=True,timeout=14)
        assert stopped.returncode==0,(stopped.stdout,stopped.stderr)
        thread.join(5)
        for _ in range(80):
            if all(not group_exists(pid) for pid in pids):break
            time.sleep(.05)
        assert all(not group_exists(pid) for pid in pids),f'leftover process groups {pids}'
        assert not error,error
        print('PASS service shutdown cleans synchronous and asynchronous shell groups',flush=True)
    finally:
        subprocess.run([str(BINARY),'stop'],env=env,capture_output=True,timeout=8)
