"""Schema and safety checks for the observed distribution inventory/BOM."""
import json
from pathlib import Path
import unittest

HERE = Path(__file__).resolve().parent


class InventoryContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.inventory = json.loads((HERE / 'inventory-snapshot.json').read_text())
        cls.bom = json.loads((HERE / 'bom-candidate.json').read_text())

    def test_capability_matrix_is_unique_and_has_required_fields(self):
        items = self.inventory['capability_matrix']
        self.assertGreaterEqual(len(items), 20)
        ids = [item['id'] for item in items]
        self.assertEqual(len(ids), len(set(ids)))
        required = ('id', 'owner', 'source', 'permissions', 'dependencies',
                    'lifecycle_owner', 'health_probe', 'data_paths', 'secret_policy',
                    'update', 'rollback', 'uninstall', 'packaging', 'acceptance')
        for item in items:
            self.assertTrue(all(field in item for field in required), item.get('id'))
            self.assertEqual(item['acceptance'], 'NOT_VERIFIED')
            self.assertNotEqual(item['secret_policy'], '')
        for state in ('needs_authorization', 'unsupported', 'degraded', 'failed'):
            self.assertIn(state, self.inventory['readiness_states'])

    def test_service_and_skill_inventory_contains_no_secret_payloads(self):
        services = self.inventory['pm2']['items']
        skills = self.inventory['skills']['items']
        self.assertEqual(self.inventory['pm2']['count'], len(services))
        self.assertEqual(self.inventory['skills']['count'], len(skills))
        for service in services:
            self.assertTrue(set(service).isdisjoint({'env', 'pm2_env', 'password', 'token'}))
            self.assertEqual(service['secrets'], 'NOT_EXPORTED')
        self.assertIn('vlog-inbox-watcher', [s['name'] for s in services])
        stopped = next(s for s in services if s['name'] == 'vlog-inbox-watcher')
        self.assertEqual(stopped['status'], 'stopped')

    def test_release_bom_never_claims_unverified_candidate_is_ready(self):
        self.assertFalse(self.bom['release_ready'])
        components = {c['component']:c for c in self.bom['components']}
        self.assertEqual(components['neo-core']['npm_name'], '@lalalic/neo')
        self.assertTrue(components['neo-core']['npm_integrity'].startswith('sha512-'))
        self.assertEqual(len(components['neo-core']['candidate_artifact_sha256']), 64)
        self.assertTrue(components['neo-core']['source_bundled_bytes_match'])
        self.assertEqual(components['neo-core']['source_file_count'], components['neo-core']['bundled_file_count'])
        self.assertFalse(components['neo-native-app']['signed_release'])
        self.assertIsNone(components['neo-native-app']['artifact_uri'])
        self.assertTrue(self.bom['missing_release_gates'])


if __name__ == '__main__':
    unittest.main(verbosity=2)
