#!/usr/bin/env python3
"""Bundled Frida command dispatch; no server or downloads."""
from pathlib import Path
import subprocess
import unittest

REPO = Path(__file__).resolve().parents[1]
HARNESS = r'''
SCRIPT_DIR=$1
shift
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/frida.sh"
frida_require_running() { :; }
frida_host() { printf '%s\0' "$@"; }
cmd_frida "$@"
'''


class FridaTests(unittest.TestCase):
    def run_frida(self, *args, ok=True):
        result = subprocess.run(["bash", "-c", HARNESS, "test", str(REPO), *args], capture_output=True, timeout=10)
        self.assertEqual(result.returncode == 0, ok, result.stderr.decode())
        return result.stdout.decode().rstrip("\0").split("\0")

    def test_script_dispatch_preserves_frida_parameters(self):
        parameters = '{"flutterOffset":"0x100", "flutterBytes":"0011223344556677", "flutterVerifier":"chain"}'
        for script in ("crypto", "conceal", "native-unpin", "flutter-unpin"):
            self.assertEqual(self.run_frida("script", script, "com.example.app", "-P", parameters),
                             ["frida", "-f", "com.example.app", "-l", str(REPO / "frida" / f"{script}.js"), "-P", parameters])

    def test_invalid_scripts_and_packages_fail(self):
        for args in (("script",), ("script", "../unpin", "com.example.app"),
                     ("script", "crypto", "-f"), ("unpin", "com.example.app", "extra"),
                     ("unpin", "com.app;id")):
            self.run_frida(*args, ok=False)

    def test_existing_unpin_remains_available(self):
        self.assertEqual(self.run_frida("unpin", "com.example.app"),
                         ["frida", "-f", "com.example.app", "-l", str(REPO / "frida/unpin.js")])


if __name__ == "__main__":
    unittest.main()
