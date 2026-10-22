#!/usr/bin/env python3
"""Legacy CLI contract/golden fixtures; isolated from the live Workspace."""
import json
import os
import site
from pathlib import Path
import subprocess
import tempfile
import unittest
from zipfile import ZipFile

NEO = Path(__file__).resolve().parents[5] / 'neo'
PROJECTS = NEO / 'skills/xchat-orchestrator/scripts/list-xchat-projects'
SKILLS = NEO / 'skills/xchat-orchestrator/scripts/list-xchat-skills'


class LegacyXChatFixtures(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='neo-p0-cli-')
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name).resolve()
        self.workspace = self.home / 'Workspace'
        self.workspace.mkdir()
        self.env = dict(os.environ, HOME=str(self.home),
                        PYTHONPATH=os.pathsep.join(filter(None,
                          [site.getusersitepackages(), os.environ.get("PYTHONPATH", "")])))
        (self.home / '.agents').mkdir()
        (self.home / '.agents/AGENTS.md').write_text('global\n')

    def invoke(self, executable, *args):
        return subprocess.run([str(executable), *args], text=True, capture_output=True, env=self.env, timeout=20)

    def checkout(self, name, repo):
        root = self.workspace / name
        root.mkdir(parents=True)
        subprocess.run(['git', 'init', '-q', str(root)], check=True, stdout=subprocess.DEVNULL)
        subprocess.run(['git', '-C', str(root), 'remote', 'add', 'origin', f'git@github.com:{repo}.git'], check=True)
        (root / 'AGENTS.md').write_text('root\n')
        (root / 'README.md').write_text('readme\n')
        return root

    def skill(self, root, name, description, requires=''):
        p = root / name
        p.mkdir(parents=True)
        (p / 'SKILL.md').write_text(f'---\nname: {name}\ndescription: {description}\n{requires}---\n')

    def test_project_resolution_golden_and_ordered_context(self):
        root = self.checkout('neox', 'lalalic/neox')
        result = self.invoke(PROJECTS, '--resolve', 'neox')
        self.assertEqual(result.returncode, 0, result.stderr)
        data = json.loads(result.stdout)
        self.assertEqual([data[x] for x in ('xchat_project','name','repo')], ['neox','neox','lalalic/neox'])
        self.assertEqual([Path(p).name for p in data['context_files']], ['AGENTS.md','AGENTS.md','README.md'])
        self.assertEqual(data['git_root'], str(root))

    def test_nested_project_without_local_agents(self):
        root = self.checkout('neo', 'lalalic/neo')
        folder = root / 'vlog/episode'
        folder.mkdir(parents=True)
        result = self.invoke(PROJECTS, '--resolve', 'neo/vlog/episode')
        self.assertEqual(result.returncode, 0, result.stderr)
        data = json.loads(result.stdout)
        self.assertEqual(data['git_root'], str(root))
        self.assertEqual(data['xchat_project'], 'neo/vlog/episode')
        self.assertEqual([Path(p).name for p in data['context_files']], ['AGENTS.md', 'AGENTS.md'])

    def test_ambiguous_and_missing_project_fail_nonzero(self):
        for name in ('one/project', 'two/project'):
            self.checkout(name, 'lalalic/' + name.replace('/','-'))
        ambiguous = self.invoke(PROJECTS, '--resolve', 'project')
        self.assertNotEqual(ambiguous.returncode, 0)
        self.assertIn('ambiguous xchat project', ambiguous.stderr)
        missing = self.invoke(PROJECTS, '--resolve', 'not-present')
        self.assertNotEqual(missing.returncode, 0)
        self.assertIn('xchat project not found', missing.stderr)

    def test_skill_layer_override_golden(self):
        global_skills = self.home / '.agents/skills'
        neo_skills = self.workspace / 'neo/skills'
        local = self.workspace / 'neox/skills'
        for layer, desc in ((global_skills,'global'),(neo_skills,'neo'),(local,'project')):
            self.skill(layer, 'same', desc)
        self.skill(global_skills, 'only-global', 'global')
        result = self.invoke(SKILLS, '--project', str(local.parent))
        self.assertEqual(result.returncode, 0, result.stderr)
        items = {x['name']:x for x in json.loads(result.stdout)}
        self.assertEqual(items['same']['description'], 'project')
        self.assertEqual(items['only-global']['description'], 'global')
        self.assertTrue(items['same']['path'].startswith(str(local)))

    def test_missing_skill_dependency_fails_closed(self):
        global_skills = self.home / '.agents/skills'
        self.skill(global_skills, 'dependent', 'depends', 'requires:\n  skills:\n    - missing\n')
        result = self.invoke(SKILLS)
        self.assertEqual(result.returncode, 0, result.stderr)
        value = json.loads(result.stdout)[0]
        self.assertFalse(value['requires_resolved'])
        self.assertEqual(value['missing_required_skills'], ['missing'])


    def test_chatgpt_packager_text_only_golden(self):
        skill = self.home / 'demo-skill'
        skill.mkdir()
        (skill / 'SKILL.md').write_text('---\nname: demo-skill\ndescription: test\n---\n')
        (skill / 'readme.txt').write_text('text only')
        (skill / 'binary.dat').write_bytes(b'\x00\xff')
        (skill / 'node_modules').mkdir()
        (skill / 'node_modules' / 'skip.txt').write_text('excluded')
        output = self.home / 'test.zip'
        cmd = self.invoke(NEO / '.bin/package-web-chatgpt-skill', str(skill), str(output))
        self.assertEqual(cmd.returncode, 0, cmd.stderr)
        self.assertEqual(cmd.stdout.strip(), str(output))
        with ZipFile(output) as archive:
            self.assertEqual(sorted(archive.namelist()),
                             ['demo-skill/SKILL.md', 'demo-skill/readme.txt'])
        missing = self.invoke(NEO / '.bin/package-web-chatgpt-skill',
                              str(skill / 'missing'), str(self.home / 'other.zip'))
        self.assertNotEqual(missing.returncode, 0)
        self.assertIn('missing', missing.stderr)

    def test_queue_rejects_run_without_worker_and_preserves_disk(self):
        env = dict(self.env, NEO_QUEUE_HOME=str(self.home / 'isolated-queue'))
        cmd = subprocess.run(['node', str(NEO / '.bin/neo-queue.mjs'),
                              'run', '--', '/bin/true'],
                             env=env, text=True, capture_output=True, timeout=15)
        self.assertNotEqual(cmd.returncode, 0)
        self.assertIn('Queue worker unavailable', cmd.stderr)
        self.assertTrue((self.home / 'isolated-queue/queue.sqlite').is_file())
        self.assertEqual(self.invoke(NEO / '.bin/neo.mjs', '--help').returncode, 0)

    def test_updater_contract_is_pure_and_does_not_control_services(self):
        script = (NEO / '.bin/package-service-updater.mjs').as_uri()
        code = f"""import {{publicationFromEvent, discoverPackageServices}} from '{script}';
const evt = {{type:'package.published',status:'succeeded',data:{{package:'agents-relay',version:'2.0.141'}}}};
const event = publicationFromEvent(evt);
const services = discoverPackageServices([{{name:'agents-relayd',pm2_env:{{pm_exec_path:'/opt/homebrew/bin/npx',status:'online',args:['--package','agents-relay@latest','agents-relayd']}}}}], 'agents-relay');
console.log(JSON.stringify({{event,services}}));"""
        out = subprocess.run(['node', '--input-type=module', '--eval', code],
                             text=True, capture_output=True, timeout=15, env=self.env)
        self.assertEqual(out.returncode, 0, out.stderr)
        obj = json.loads(out.stdout)
        self.assertEqual(obj['event']['packageName'], 'agents-relay')
        self.assertEqual(obj['event']['version'], '2.0.141')
        self.assertEqual(obj['services'], [{'name':'agents-relayd','status':'online'}])


if __name__ == '__main__':
    unittest.main(verbosity=2)
