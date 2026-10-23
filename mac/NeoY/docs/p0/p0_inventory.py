#!/usr/bin/env python3
"""Read-only P0 discovery: source/package/skill/service topology, never secrets.

Usage: python3 p0_inventory.py [--output /path/inventory.json]
No process control, credential reads, installations, or service mutations.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import subprocess

PROJECT = Path(__file__).resolve().parents[2]  # mac/NeoY
NEOX = PROJECT.parents[1]
WORKSPACE = NEOX.parent
NEO = WORKSPACE / 'neo'
RELAY = WORKSPACE / 'agents-relay'
BROWSER = WORKSPACE / 'browser-workspace'

STATES = ['not_installed', 'installed', 'needs_configuration',
          'needs_authorization', 'ready', 'degraded', 'unsupported', 'failed']


def source_path(path: str | Path | None) -> str | None:
    if not path:
        return None
    value = str(path)
    home = str(Path.home())
    if value.startswith(home + '/'):
        return '$HOME/' + value[len(home) + 1:]
    return value


def manifest(root: Path) -> dict:
    try:
        package = json.loads((root / 'package.json').read_text())
        return {'name': package.get('name'), 'version': package.get('version'),
                'bin': package.get('bin'), 'engines': package.get('engines'),
                'source_file': source_path(root / 'package.json')}
    except (OSError, ValueError):
        return {'source_file': source_path(root / 'package.json'),
                'status': 'NOT_VERIFIED'}


def invoke(command: list[str]) -> dict:
    try:
        done = subprocess.run(command, capture_output=True, text=True,
                              timeout=25, check=False)
        if done.returncode:
            return {'status': 'NOT_VERIFIED', 'exit_code': done.returncode}
        return {'status': 'OBSERVED', 'value': json.loads(done.stdout)}
    except (OSError, ValueError, subprocess.TimeoutExpired):
        return {'status': 'NOT_VERIFIED'}


def capabilities() -> list[dict]:
    # Each row names the actual owner, not a proposed Swift implementation.
    entries = [
        ('native-gateway', 'neox', 'mac/NeoY/Sources/NeoY/MCPServer.swift', [],
         ['local-network', 'signed-host'], 'Neo app', 'MCP initialize/tools/list',
         ['$HOME/Library/Application Support/NeoY'], 'bundled'),
        ('native-setup', 'neox', 'mac/NeoY/Sources/NeoY/SetupView.swift',
         ['native-gateway'], ['user-consent'], 'Neo app', 'setup status', [], 'bundled'),
        ('core-execution', 'neox', 'mac/NeoY/Runtime/src/core/tools/index.mjs',
         ['native-gateway', 'nodejs'], ['explicit-full-access-authorization'],
         'Neo stdio supervisor', 'MCP tools/list',
         ['$HOME/Library/Application Support/NeoY/core'], 'bundled-versioned'),
        ('xchat-projects', 'neo', 'skills/xchat-orchestrator/scripts/list-xchat-projects',
         ['core-execution', 'installed-neo-skills'], ['workspace-read'],
         'Neo dispatcher', 'resolver JSON / nonzero exit', [], 'managed-capability-pack'),
        ('xchat-skills', 'neo', 'skills/xchat-orchestrator/scripts/list-xchat-skills',
         ['core-execution', 'installed-neo-skills', 'pyyaml'], ['workspace-read'],
         'Neo dispatcher', 'precedence + dependency JSON', [], 'managed-capability-pack'),
        ('escalation', 'neo', '.bin/neo.mjs',
         ['core-execution', 'codex-provider'], ['elevated-user-approval'],
         'neo CLI owner', 'resolved/needs_user/failed', [], 'managed-capability-pack'),
        ('queue', 'neo', '.bin/neo-queue.mjs',
         ['core-execution'], ['task-context'], 'queue process owner',
         'queue CLI + worker recovery', [], 'managed-capability-pack'),
        ('chatgpt-skill-packager', 'neo', '.bin/package-web-chatgpt-skill',
         ['installed-neo-skills'], ['filesystem-write'], 'neo implementation owner',
         'ZIP checksum + output contract', [], 'managed-capability-pack'),
        ('service-updater', 'neo', '.bin/package-service-updater.mjs',
         ['managed-service-packages'], ['install-and-process-control'],
         'independent updater process', 'updater health/drift report', [], 'managed-service'),
        ('agents-relay', 'agents-relay', 'src/cli',
         ['sqlite', 'worker-providers'], ['github-auth', 'worker-auth'],
         'Relay daemon', 'durable SQLite task recovery', ['owner-defined SQLite'],
         'managed-service'),
        ('browser-workspace', 'browser-workspace', 'pyproject.toml',
         ['browser-harness', 'python3.11', 'chrome'], ['browser-profile-consent'],
         'Browser Workspace runtime', 'platform validate + session status',
         ['browser-profile-storage'], 'managed-service'),
        ('events-bus', 'neo', 'skills/events-bus', ['nats'],
         ['loopback-network'], 'events-bus service', 'correlated event readback',
         ['event-store'], 'managed-service'),
        ('family-tutor', 'external', '@lalalic/family-tutor',
         ['native-gateway', 'browser-workspace'], ['provider-auth'],
         'family-tutor service', 'federated tools/list', ['owner-defined'], 'optional-provider'),
        ('accessibility-computer', 'neox', 'mac/NeoY/Sources/NeoY',
         ['native-gateway'], ['macos-accessibility'], 'Neo native host',
         'TCC-specific E2E', [], 'native-optional'),
        ('capture-tour', 'neox', 'mac/NeoY/Sources/NeoY',
         ['native-gateway'], ['macos-screen-recording'], 'Neo native host',
         'capture evidence', [], 'native-optional'),
        ('demo-recording', 'neox', 'mac/NeoY/Sources/NeoY',
         ['native-gateway'], ['macos-screen-recording'], 'Neo native host',
         'demo artifact', [], 'native-optional'),
        ('phone-integration', 'neox', 'mac/NeoY/Sources/NeoY/CoreNode.swift',
         ['native-gateway', 'trusted-node'], ['device-pairing', 'local-network'],
         'Neo native host', 'paired node status', [], 'native-optional'),
        ('public-tunnel', 'neox', 'mac/NeoY/Sources/NeoY/TunnelRuntime.swift',
         ['native-gateway', 'cloudflared'], ['explicit-public-exposure'],
         'Neo tunnel supervisor', 'external authenticated endpoint', [], 'native-optional'),
        ('voice', 'optional', 'neo/skills/tts-stt-sts',
         ['provider-auth', 'native-gateway'], ['microphone', 'speech-provider'],
         'optional voice provider', 'audio input/output E2E', [], 'optional-provider'),
        ('homekit', 'optional', 'homekit-adapter',
         ['native-gateway', 'trusted-network'], ['homekit-pairing'],
         'optional adapter', 'read vs write gate', [], 'optional-provider'),
        ('roku', 'neo', 'skills/play-to-roku',
         ['native-gateway', 'local-network'], ['device-network-authorization'],
         'optional Roku adapter', 'TV action evidence', [], 'optional-provider'),
        ('markcut-vlog', 'neo', 'vlog',
         ['markcut', 'workflow-authorizations'], ['source-media-license'],
         'project workflow', 'immutable preview review', [], 'project-capability'),
        ('remote-cluster', 'neox', 'mac/NeoY/Sources/NeoY/CoreNode.swift',
         ['native-gateway', 'trusted-network'], ['explicit-pairing'],
         'Neo native host', 'reconnect and offline state', [], 'native-optional'),
    ]
    return [dict(id=i, owner=o, source=s, packaging=k, dependencies=d,
                 permissions=p, lifecycle_owner=l, health_probe=h, data_paths=data,
                 secret_policy='never copy or export secrets; consent scoped to owner',
                 update='version pinned + compatibility health gate',
                 rollback='restore executable/config; preserve durable user data',
                 uninstall='preserve user data by default',
                 release_artifact=None, artifact_integrity=None,
                 os_cpu='NOT_VERIFIED', acceptance='NOT_VERIFIED')
            for i, o, s, d, p, l, h, data, k in entries]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    skills_result = invoke([str(NEO / 'skills/xchat-orchestrator/scripts/list-xchat-skills'),
                            '--project', str(NEOX)])
    services_result = invoke(['npx', 'pm2', 'jlist'])
    raw_services = services_result.get('value', [])
    service_owners = {
        'events-bus': ('NATS binary', 'nats-server'),
        'events-bus-service': ('lalalic/neo', 'skills/events-bus/api/server.mjs'),
        'wechat-bro-daemon': ('wechat-bro package', 'managed npm service'),
        'wechat-bro-orchestrator': ('wechat-bro package', 'managed npm service'),
        'neo-package-service-updater': ('lalalic/neo', '.bin/package-service-updater.mjs'),
        'agents-relay-dashboard-tunnel': ('agents-relay deployment', 'cloudflared'),
        'vlog-inbox-watcher': ('vlog project', 'managed npm service'),
        'neoy-family-tutor': ('@lalalic/family-tutor', 'federated provider'),
        'neo-queue-worker': ('lalalic/neo', 'skills/queue/queue.mjs'),
        'agents-relayd': ('agents-relay', 'managed npm daemon'),
    }
    services = []
    if isinstance(raw_services, list):
        for item in raw_services:
            env = item.get('pm2_env', {})
            services.append({'name': item.get('name'), 'status': env.get('status'),
                             'launcher': source_path(env.get('pm_exec_path')),
                             'version': env.get('version'),
                             'owner': service_owners.get(item.get('name'), ('NOT_VERIFIED', 'NOT_VERIFIED'))[0],
                             'implementation': service_owners.get(item.get('name'), ('NOT_VERIFIED', 'NOT_VERIFIED'))[1],
                             'owner_evidence': 'name/launcher association; actual process contract NOT_VERIFIED',
                             'health': 'NOT_VERIFIED',
                             'secrets': 'NOT_EXPORTED',
                             'deploy_owner': 'existing supervisor; no takeover'})
    observed_skills = []
    if isinstance(skills_result.get('value'), list):
        for item in skills_result['value']:
            observed_skills.append({'name': item['name'], 'source': source_path(item['path']),
                                    'requires': item.get('requires', {}),
                                    'requires_resolved': item.get('requires_resolved'),
                                    'missing_required_skills': item.get('missing_required_skills')})
    result = dict(schema='neo.p0.inventory.v1', created_at=datetime.now(timezone.utc).isoformat(),
                  source_kind='local read-only observation (not a release BOM)',
                  readiness_states=STATES,
                  package_sources={
                      'native_core': manifest(PROJECT / 'Runtime'),
                      'legacy_neo': manifest(NEO),
                      'agents_relay_checkout': manifest(RELAY),
                      'browser_workspace_checkout': manifest(BROWSER)},
                  capability_matrix=capabilities(),
                  skills=dict(status=skills_result['status'], count=len(observed_skills),
                              items=observed_skills),
                  pm2=dict(status=services_result['status'], count=len(services),
                           items=services),
                  limitations=['Observed service status is not E2E readiness',
                               'Live state is local-node only',
                               'Unknown artifact hashes/permissions are NOT_VERIFIED',
                               'No registry credentials, user environment, tokens or raw PM2 data persisted'])
    text = json.dumps(result, ensure_ascii=False, indent=2) + '\n'
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(text)
    else:
        print(text)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
