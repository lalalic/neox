"""Use NEO_P0_APP_BUNDLE to check Core without developer checkout or service restart."""
import json
import os
from pathlib import Path
import select
import subprocess
import tempfile
import unittest


class StandaloneCoreTest(unittest.TestCase):
    def test_unsigned_candidate_is_checkout_independent_and_fail_closed(self):
        app_path = os.environ.get('NEO_P0_APP_BUNDLE')
        if not app_path:
            self.skipTest('NOT_RUN: set NEO_P0_APP_BUNDLE to a locally built .app')
        app = Path(app_path)
        entry = app / 'Contents/Resources/Runtime/src/core/tools/index.mjs'
        self.assertTrue(entry.is_file(), 'packaged Core entrypoint absent')
        self.assertFalse(str(entry).startswith(str(Path.home() / 'Workspace')))
        with tempfile.TemporaryDirectory(prefix='neo-p0-isolation-') as temp:
            env = dict(os.environ, HOME=temp, NEO_CORE_DATA_DIR=temp + '/core',
                       NEO_CORE_UNLOCK_FILE=temp + '/unlock')
            env.pop('NEO_CORE_FULL_ACCESS_ACK', None)
            locked = subprocess.run(['node', str(entry)], env=env, capture_output=True,
                                    text=True, timeout=10)
            self.assertEqual(locked.returncode, 78)
            self.assertIn('Refusing to start unrestricted', locked.stderr)

            # Isolated test-only authorization: no actual tools/call is sent.
            Path(temp, 'unlock').write_text('I_UNDERSTAND_THIS_GRANTS_FULL_ACCESS\n')
            process = subprocess.Popen(['node', str(entry)], env=env,
                                       stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                       stderr=subprocess.PIPE, text=True, bufsize=1)
            try:
                def send(payload):
                    process.stdin.write(json.dumps(payload) + '\n')
                    process.stdin.flush()

                send({'jsonrpc':'2.0','id':1,'method':'initialize',
                      'params':{'protocolVersion':'2025-11-25', 'capabilities':{},
                                'clientInfo':{'name':'p0-source-free-test','version':'1'}}})
                response = json.loads(process.stdout.readline())
                self.assertEqual(response['result']['serverInfo']['name'], 'neo-core-tools')
                send({'jsonrpc':'2.0', 'method':'notifications/initialized','params':{}})
                send({'jsonrpc':'2.0','id':2,'method':'tools/list','params':{}})
                ready, _, _ = select.select([process.stdout], [], [], 7)
                self.assertTrue(ready, 'MCP tools/list timed out')
                response = json.loads(process.stdout.readline())
                self.assertNotIn('error', response)
                self.assertGreaterEqual(len(response['result']['tools']), 5)
            finally:
                if process.stdin and not process.stdin.closed:
                    process.stdin.close()
                try:
                    process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    process.terminate()
                    process.wait(timeout=3)
            if process.stdout:
                process.stdout.close()
            if process.stderr:
                process.stderr.close()
            self.assertEqual(process.returncode, 0)


if __name__ == '__main__':
    unittest.main(verbosity=2)
