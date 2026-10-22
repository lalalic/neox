#!/usr/bin/env python3
"""Read-only P0 source-contract audit. Run with python3 test_p0_contract.py."""
import json
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[4]
NEO = ROOT.parent / 'neo'
RUNTIME = ROOT / 'mac/NeoY/Runtime'
SWIFT = ROOT / 'mac/NeoY/Sources/NeoY/BundledRuntime.swift'


class P0SourceContracts(unittest.TestCase):
    def test_repository_identity_and_bins(self):
        app = json.loads((RUNTIME / 'package.json').read_text())
        self.assertEqual(app['name'], '@lalalic/neo')
        self.assertTrue((RUNTIME / 'src/core/tools/index.mjs').is_file())
        cli = json.loads((NEO / 'package.json').read_text())
        self.assertEqual(cli['name'], 'neo')
        self.assertIn('neo', cli['bin'])
        self.assertIn('neo-queue', cli['bin'])
        self.assertNotEqual(app['name'], cli['name'])

    def test_legacy_cli_consumers_exist(self):
        base = NEO / 'skills/xchat-orchestrator'
        bootstrap = (base / 'xchat-bootstrap.md').read_text()
        for executable in ('list-xchat-projects', 'list-xchat-skills'):
            self.assertIn(executable, bootstrap)
            self.assertTrue((base / 'scripts' / executable).is_file())
        for script in ('neo.mjs', 'neo-queue.mjs', 'package-web-chatgpt-skill', 'package-service-updater.mjs'):
            self.assertTrue((NEO / '.bin' / script).exists(), script)

    def test_release_core_must_not_default_to_checkout(self):
        self.assertNotIn('repoRuntimeURL', SWIFT.read_text())
        self.assertIn('packagedRuntimeURL', SWIFT.read_text())
        self.assertIn('path: Runtime', (ROOT / 'mac/NeoY/project.yml').read_text())

    def test_release_core_must_not_ack_full_access_by_default(self):
        self.assertNotIn('"NEO_CORE_FULL_ACCESS_ACK": "I_UNDERSTAND_THIS_GRANTS_FULL_ACCESS"', SWIFT.read_text())


if __name__ == '__main__':
    unittest.main(verbosity=2)
