"""Isolated rollback test. Never call launchctl or touch /Applications."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[2] / "Resources/Scripts/upgrade-watchdog.sh"

class WatchdogTests(unittest.TestCase):
    def test_unhealthy_candidate_rolls_back_to_prior_bundle(self):
        with tempfile.TemporaryDirectory(prefix="neo-watchdog-") as tmp:
            root = Path(tmp)
            target = root / "NeoY.app"
            old = root / "NeoY.previous.app"
            for base, label in ((target, "broken"), (old, "previous")):
                exe = base / "Contents/MacOS/NeoY"
                exe.parent.mkdir(parents=True)
                exe.write_text(label)
                exe.chmod(0o755)
            trigger = root / "trigger"
            trigger.touch()
            env = dict(os.environ, NEOY_TEST_MODE="1", NEOY_DEST=str(target),
                NEOY_BACKUP=str(old), NEOY_TRIGGER_FILE=str(trigger),
                NEOY_UPGRADE_LOG=str(root / "upgrade.log"),
                NEOY_STARTUP_TIMEOUT="1", NEOY_ROLLBACK_TIMEOUT="1",
                NEOY_HEALTH_URL="http://127.0.0.1:1/no-listener",
                NEOY_EXPECTED_HASH="intentionally-invalid")
            result = subprocess.run(["/bin/zsh", str(SCRIPT)], env=env,
                                    capture_output=True, text=True, timeout=12)
            self.assertEqual(result.returncode, 3, result.stderr)
            self.assertEqual((target / "Contents/MacOS/NeoY").read_text(), "previous")
            self.assertFalse(old.exists())
            self.assertIn("rolling back", (root / "upgrade.log").read_text())

if __name__ == "__main__": unittest.main()
