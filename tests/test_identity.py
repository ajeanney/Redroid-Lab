#!/usr/bin/env python3
"""Exercise startup argument generation with all host mutation helpers replaced."""
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]
HARNESS = r'''
set -Eeuo pipefail
SCRIPT_DIR=$1
CONFIG_FILE=$2
STATE_DIR=$3
STATE_FILE=$STATE_DIR/state.env
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/lifecycle.sh"
load_config
acquire_lock() { :; }
require_runtime_tools() { :; }
container_running() { return 1; }
container_exists() { return 1; }
preflight() { :; }
write_state() { : >"$STATE_FILE"; }
install_adb_guard() { :; }
network_hash() { echo test-hash; }
wait_for_android() { :; }
verify_network_unchanged() { :; }
verify_native_bridge() { :; }
rollback_start() { exit 1; }
docker() { printf '%s\0' "$@" >"$STATE_DIR/docker-args"; }
cmd_start --no-bt
'''


class IdentityTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.config = self.root / "test.env"

    def start(self, overrides=None, old_config=False, ok=True):
        config = (REPO / "redroid.env").read_text()
        if old_config:
            config = "\n".join(line for line in config.splitlines() if not line.startswith((
                "REDROID_MODEL=", "REDROID_MANUFACTURER=", "REDROID_BRAND=", "REDROID_DEVICE=",
                "REDROID_PRODUCT=", "REDROID_FINGERPRINT=", "REDROID_QEMU=", "CAMERA_ENABLE=")))
        overrides = {"REDROID_DATA_DIR": str(self.root / "data"), **(overrides or {})}
        self.config.write_text(config + "\n" + "\n".join(f"{key}={shlex.quote(value)}" for key, value in overrides.items()))
        state = Path(tempfile.mkdtemp(dir=self.root))
        result = subprocess.run(["bash", "-c", HARNESS, "test", str(REPO), str(self.config), str(state)],
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode == 0, ok, result.stdout + result.stderr)
        path = state / "docker-args"
        return path.read_bytes().decode().rstrip("\0").split("\0") if path.exists() else []

    def test_empty_and_legacy_configs_preserve_image_identity(self):
        for legacy in (False, True):
            args = self.start(old_config=legacy)
            self.assertFalse(any(a.startswith(("ro.product.model=", "ro.build.fingerprint=", "ro.kernel.qemu=")) for a in args))
            self.assertIn("127.0.0.1:5555:5555", args)
            self.assertIn("ro.product.cpu.abilist=x86_64,x86,arm64-v8a", args)
            self.assertIn("ro.redroid.camera=1", args)

    def test_synthetic_camera_switch(self):
        for enabled in ("0", "1"):
            with self.subTest(enabled=enabled):
                args = self.start({"CAMERA_ENABLE": enabled})
                self.assertIn(f"ro.redroid.camera={enabled}", args)
        self.assertEqual(self.start({"CAMERA_ENABLE": "2"}, ok=False), [])

    def test_properties_are_single_arguments_after_the_image(self):
        values = {"REDROID_MODEL": "Lab Phone $(touch nope)", "REDROID_MANUFACTURER": "Lab Maker",
                  "REDROID_BRAND": "lab", "REDROID_DEVICE": "lab-device", "REDROID_PRODUCT": "lab-product",
                  "REDROID_FINGERPRINT": "lab/product/device:14/id/build:user/release-keys", "REDROID_QEMU": "0"}
        args = self.start(values)
        for prop, key in (("ro.product.model", "REDROID_MODEL"), ("ro.product.manufacturer", "REDROID_MANUFACTURER"),
                          ("ro.product.brand", "REDROID_BRAND"), ("ro.product.device", "REDROID_DEVICE"),
                          ("ro.product.name", "REDROID_PRODUCT"), ("ro.build.fingerprint", "REDROID_FINGERPRINT"),
                          ("ro.kernel.qemu", "REDROID_QEMU")):
            self.assertIn(f"{prop}={values[key]}", args)
            self.assertGreater(args.index(f"{prop}={values[key]}"), args.index("redroid-lab:14"))
        self.assertNotIn("--mount", args)

    def test_invalid_values_fail_before_any_start(self):
        for overrides in ({"REDROID_QEMU": "2"}, {"REDROID_MODEL": "line1\nline2"},
                          {"REDROID_FINGERPRINT": "value\r"}, {"ADB_HOST": "0.0.0.0"}):
            with self.subTest(overrides=overrides):
                self.assertEqual(self.start(overrides, ok=False), [])


if __name__ == "__main__":
    unittest.main()
