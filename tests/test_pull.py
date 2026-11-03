#!/usr/bin/env python3
"""APK extraction checks with fake ADB, apktool and jadx; no guest required."""
import fcntl
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[1]
PACKAGE = "com.example.app"
PATHS = "/data/app/~~token/com.example.app==/"
FAKE_COMMAND = f"#!{sys.executable}\n" + r'''
import fcntl
import json
import os
from pathlib import Path
import sys

root = Path(os.environ["PULL_TEST_ROOT"])
cmd = Path(sys.argv[0]).name
args = sys.argv[1:]
fault = os.environ.get("PULL_TEST_FAULT", "")
with (root / "events").open("a") as log:
    log.write(json.dumps([cmd, *args]) + "\n")
if cmd == "adb":
    if args[0] == "connect":
        sys.exit(fault == "connect")
    if args[2:5] == ["shell", "pm", "path"]:
        sys.stdout.write(os.environ["PULL_TEST_PATHS"])
        sys.exit(fault == "query")
    if args[2] == "pull":
        with (root / ".runtime/lock").open("w") as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                pass
            else:
                sys.exit("APK extraction must hold the lifecycle lock")
        if fault == "directory":
            Path(args[4]).mkdir()
        else:
            Path(args[4]).write_text("" if fault == "empty" else args[3])
        sys.exit(fault == "pull")
    if args[2] in ("install", "install-multiple"):
        sys.exit(0)
    sys.exit("unexpected adb command: " + repr(args))
with (root / ".runtime/lock").open("w") as lock:
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
if cmd == "apktool":
    assert args[0] == "d" and args[2] == "-o", args
    output = Path(args[3])
    output.mkdir(parents=True)
    sdk = '<uses-sdk android:targetSdkVersion="34"/>' if '--match-original' in args else ''
    (output / "AndroidManifest.xml").write_text('<manifest xmlns:android="http://schemas.android.com/apk/res/android" package="com.example.app">' + sdk + '<application><activity android:name=".Public" android:exported="true"/><provider android:name=".Private"/></application></manifest>')
elif cmd == "jadx":
    assert args[0] == "-d", args
    output = Path(args[1])
    output.mkdir(parents=True)
    (output / "App.java").write_text("decompiled")
else:
    sys.exit("unexpected tool: " + cmd)
sys.exit(fault in (cmd, "analysis"))
'''


class PullTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="redroid-pull-test-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        shutil.copy2(REPO / "redroid.sh", self.root)
        shutil.copytree(REPO / "lib", self.root / "lib")
        shutil.copy2(REPO / "redroid.env", self.root)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        for name in ("bash", "dirname", "mkdir", "flock", "tr", "date", "mktemp", "mv", "python3"):
            (self.bin / name).symlink_to(shutil.which(name))
        for name in ("adb", "apktool", "jadx"):
            command = self.bin / name
            command.write_text(FAKE_COMMAND)
            command.chmod(0o755)
        self.env = dict(os.environ, PATH=str(self.bin), PULL_TEST_ROOT=str(self.root),
                        PULL_TEST_PATHS=f"package:{PATHS}base.apk\r\n")
        self.env.pop("REDROID_CONFIG", None)
        self.env.pop("PULL_DIR", None)

    def run_command(self, *args, ok=True, fault=""):
        result = subprocess.run(
            [str(self.bin / "bash"), str(self.root / "redroid.sh"), *args],
            env=dict(self.env, PULL_TEST_FAULT=fault), capture_output=True, text=True, timeout=10,
        )
        self.assertEqual(result.returncode == 0, ok, result.stdout + result.stderr)
        return result

    def events(self):
        path = self.root / "events"
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def outputs(self):
        return sorted((self.root / "apps" / PACKAGE).glob("*"))

    def test_split_pull_preserves_names_and_can_be_reinstalled(self):
        names = ("base.apk", "split_config.arm64_v8a.apk", "split_feature.apk")
        self.env["PULL_TEST_PATHS"] = "".join(f"package:{PATHS}{name}\r\n" for name in names)
        self.run_command("pull", PACKAGE)
        output, = self.outputs()
        self.assertEqual(sorted(p.name for p in output.iterdir()), sorted(names))
        self.assertEqual(output.stat().st_mode & 0o777, 0o700)
        for name in names:
            self.assertEqual((output / name).read_text(), PATHS + name)
        self.run_command("install", str(output))
        install = self.events()[-1]
        self.assertEqual(install[:4], ["adb", "-s", "127.0.0.1:5555", "install-multiple"])
        self.assertEqual(sorted(install[6:]), sorted(str(output / name) for name in names))

    def test_single_apk_and_repeat_pulls_do_not_overwrite(self):
        self.env["PULL_TEST_PATHS"] = "package:/system/app/Example/Example.apk\n"
        self.run_command("pull", PACKAGE)
        first, = self.outputs()
        (first / "Example.apk").write_text("keep original")
        self.run_command("pull", PACKAGE)
        self.assertEqual(len(self.outputs()), 2)
        self.assertEqual((first / "Example.apk").read_text(), "keep original")

    def test_optional_analysis_receives_all_apks_and_releases_lock(self):
        self.env["PULL_TEST_PATHS"] += f"package:{PATHS}split_config.en.apk\r\n"
        for flags in (("--apktool",), ("--jadx",), ("--apktool", "--jadx")):
            with self.subTest(flags=flags):
                before = set(self.outputs())
                self.run_command("pull", PACKAGE, *flags)
                output, = set(self.outputs()) - before
                self.assertEqual((output / "apktool").exists(), "--apktool" in flags)
                self.assertEqual((output / "jadx").exists(), "--jadx" in flags)
                if "--apktool" in flags:
                    self.assertTrue((output / "apktool/base/AndroidManifest.xml").exists())
                    self.assertTrue((output / "apktool/split_config.en/AndroidManifest.xml").exists())
                if "--jadx" in flags:
                    call = self.events()[-1]
                    self.assertEqual(call[:3], ["jadx", "-d", str(output / "jadx")])
                    self.assertEqual(call[3:], [str(output / "base.apk"), str(output / "split_config.en.apk")])

    def test_report_uses_decoded_xml_and_keeps_apks(self):
        self.run_command("pull", PACKAGE, "--report")
        output, = self.outputs()
        report = json.loads((output / "report.json").read_text())
        self.assertEqual(report["target_sdk"], "34")
        self.assertEqual([c["name"] for c in report["exported_components"]], [PACKAGE + ".Public"])
        self.assertIn("--match-original", next(e for e in self.events() if e[0] == "apktool"))
        self.assertTrue((output / "base.apk").exists())
        self.assertTrue((output / "apktool/base/AndroidManifest.xml").exists())

    def test_report_failure_is_nonzero_and_other_analysis_still_runs(self):
        self.run_command("pull", PACKAGE, "--report", "--jadx", fault="apktool", ok=False)
        output, = self.outputs()
        self.assertTrue((output / "jadx/App.java").exists())
        self.assertTrue((output / "base.apk").exists())

    def test_invalid_args_do_not_contact_guest(self):
        for args in ((), ("../escape",), ("com.app;id",), (PACKAGE, "--unknown"), (PACKAGE, "extra")):
            self.run_command("pull", *args, ok=False)
        self.assertEqual(self.events(), [])

    def test_missing_optional_tools_fail_before_guest_contact(self):
        for tool in ("apktool", "jadx"):
            (self.bin / tool).unlink()
            self.run_command("pull", PACKAGE, f"--{tool}", ok=False)
        self.assertEqual(self.events(), [])

    def test_bad_or_duplicate_guest_paths_do_not_create_output(self):
        for paths in ("", "Error: unknown package", "package:relative.apk", "package:/data/evil;name.apk",
                      "package:/data/a/base.apk\npackage:/data/b/base.apk"):
            self.env["PULL_TEST_PATHS"] = paths
            self.run_command("pull", PACKAGE, ok=False)
        self.assertFalse((self.root / "apps").exists())

    def test_adb_failures_return_errors_without_analysis(self):
        for fault in ("connect", "query", "pull", "empty", "directory"):
            with self.subTest(fault=fault):
                self.run_command("pull", PACKAGE, "--apktool", "--jadx", fault=fault, ok=False)
        self.assertFalse(any(e[0] != "adb" for e in self.events()))
        for output in self.outputs():
            self.assertEqual(list(output.glob("*.apk")), [])
            self.assertTrue((output / "base.apk.part").exists())

    def test_analysis_failure_keeps_apks_and_runs_both_tools(self):
        result = self.run_command("pull", PACKAGE, "--apktool", "--jadx", fault="analysis", ok=False)
        output, = self.outputs()
        self.assertTrue((output / "base.apk").exists())
        self.assertTrue((output / "apktool/base/AndroidManifest.xml").exists())
        self.assertTrue((output / "jadx/App.java").exists())
        self.assertIn("static analysis failed", result.stderr)

    def test_old_local_config_and_custom_output_path_with_spaces(self):
        config = self.root / "old.local.env"
        config.write_text("\n".join(line for line in (self.root / "redroid.env").read_text().splitlines()
                                    if not line.startswith("PULL_DIR=")))
        self.env["REDROID_CONFIG"] = str(config)
        self.run_command("pull", PACKAGE)
        self.assertEqual(len(self.outputs()), 1)
        with config.open("a") as stream:
            stream.write("\nPULL_DIR='./custom apps'\n")
        self.run_command("pull", PACKAGE, "--apktool", "--jadx")
        output, = (self.root / "custom apps" / PACKAGE).iterdir()
        self.assertTrue((output / "jadx/App.java").exists())

    def test_lock_contention_prevents_guest_contact(self):
        (self.root / ".runtime").mkdir()
        with (self.root / ".runtime/lock").open("w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.run_command("pull", PACKAGE, ok=False)
        self.assertEqual(self.events(), [])


if __name__ == "__main__":
    unittest.main()
