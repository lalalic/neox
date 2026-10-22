"""Non-destructive installer preflight contract checks."""
import pathlib
import subprocess
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
INSTALLER = ROOT / "install-local.sh"


class InstallerSafetyTests(unittest.TestCase):
    def test_preflight_precedes_any_live_replacement(self):
        content = INSTALLER.read_text()
        preflight = content.index('CORE_ENTRY="$APP/Contents/Resources/Runtime/src/core/tools/index.mjs"')
        self.assertLess(preflight, content.index('rm -rf "$DEST.new"'))
        self.assertLess(preflight, content.index('launchctl bootout "gui/$UID/$LAUNCH_LABEL"'))
        self.assertLess(preflight, content.index('rm -rf "$DEST"'))

    def test_required_core_and_node_version_are_checked(self):
        content = INSTALLER.read_text()
        self.assertIn('[[ ! -f "$CORE_ENTRY" || ! -f "$CORE_PACKAGE" ]]', content)
        self.assertIn('process.versions.node.split', content)
        self.assertIn('>= 18', content)
        self.assertIn('exit 1', content)

    def test_existing_install_never_auto_grants_full_access(self):
        content = INSTALLER.read_text()
        self.assertIn('FULL_ACCESS_ENABLED', content)
        self.assertIn('Never mint the unlock file automatically', content)
        self.assertLess(content.index('FULL_ACCESS_ENABLED'), content.index('rm -rf "$DEST.new"'))

    def test_zsh_syntax(self):
        subprocess.run(['zsh', '-n', str(INSTALLER)], check=True, capture_output=True)


if __name__ == "__main__":
    unittest.main()
