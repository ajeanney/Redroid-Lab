#!/usr/bin/env python3
"""Exercise screen dispatch with fake ADB and scrcpy; no guest or display needed."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]


class ScreenTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.env = {
            **os.environ,
            "PATH": f"{self.root}:{os.environ['PATH']}",
            "REDROID_CONFIG": str(REPO / "redroid.env"),
            "SCREEN_ARGS": str(self.root / "args.json"),
            "BOOTED": "1",
            "MODERN": "1",
            "HELP_STDERR": "0",
        }
        scripts = {
            "adb": 'import os\nimport sys\nif "sys.boot_completed" in sys.argv: print(os.environ["BOOTED"])\n',
            "scrcpy": '''import json
import os
import signal
import sys
signal.signal(signal.SIGPIPE, signal.SIG_DFL)
if sys.argv[1:] == ["--help"]:
    stream = sys.stderr if os.environ["HELP_STDERR"] == "1" else sys.stdout
    option = "--audio-codec" if os.environ["MODERN"] == "1" else "--stay-awake"
    stream.write(option + "\\n")
    stream.flush()
    stream.write("help text\\n" * 65536)
else:
    with open(os.environ["SCREEN_ARGS"], "w") as output:
        json.dump(sys.argv[1:], output)
''',
        }
        for name, script in scripts.items():
            path = self.root / name
            path.write_text(f"#!{sys.executable}\n{script}")
            path.chmod(0o755)

    def screen(self, ok=True):
        result = subprocess.run([str(REPO / "redroid.sh"), "screen"], env=self.env,
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode == 0, ok, result.stdout + result.stderr)
        return json.loads(Path(self.env["SCREEN_ARGS"]).read_text()) if ok else []

    def test_modern_scrcpy_with_long_help_uses_aac(self):
        for stderr in ("0", "1"):
            with self.subTest(help_stderr=stderr):
                self.env["HELP_STDERR"] = stderr
                self.assertEqual(self.screen(), ["-s", "127.0.0.1:5555", "--stay-awake",
                                                "--audio-codec=aac",
                                                "--audio-encoder=OMX.google.aac.encoder"])

    def test_old_scrcpy_receives_no_audio_options(self):
        self.env["MODERN"] = "0"
        self.assertEqual(self.screen(), ["-s", "127.0.0.1:5555", "--stay-awake"])

    def test_unbooted_android_does_not_launch_scrcpy(self):
        self.env["BOOTED"] = "0"
        self.screen(ok=False)
        self.assertFalse(Path(self.env["SCREEN_ARGS"]).exists())


if __name__ == "__main__":
    unittest.main()
