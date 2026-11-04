#!/usr/bin/env python3
"""Snapshot and factory-reset checks with temporary data and fake commands."""
import fcntl
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[1]
FAKE_COMMAND = r'''#!/usr/bin/env python3
import json
import os
from pathlib import Path
import subprocess
import sys

root = Path(os.environ["SNAPSHOT_TEST_ROOT"])
state_path = root / "container.json"
state = json.loads(state_path.read_text())
cmd = Path(sys.argv[0]).name
args = sys.argv[1:]
fault = os.environ.get("SNAPSHOT_TEST_FAULT", "")
with (root / "events").open("a") as log:
    log.write(json.dumps([cmd, *args]) + "\n")
if cmd == "docker":
    if args[0] == "info":
        sys.exit(fault == "daemon")
    if args[0] == "container":
        if args[1] != "ls":
            sys.exit("unexpected container command: " + repr(args))
        if fault == "list":
            sys.exit(1)
        if state["status"] != "absent":
            print("redroid14-bt")
        sys.exit(0)
    if args[0] == "inspect":
        fmt = args[2]
        if ".Mounts" in fmt:
            print(state.get("mount", str(root / "data")))
        elif ".Status" in fmt:
            print(state["status"])
        elif ".Running" in fmt:
            print(str(state["status"] == "running").lower())
        else:
            sys.exit("unexpected inspect: " + fmt)
    elif args[0] in ("start", "stop"):
        if fault == args[0]:
            sys.exit(1)
        state["status"] = "running" if args[0] == "start" or fault == "still-running" else "exited"
        state_path.write_text(json.dumps(state))
    elif args[0] == "logs":
        pass
    else:
        sys.exit("unexpected docker: " + repr(args))
elif cmd == "sudo":
    if args == ["-v"]:
        sys.exit(0)
    if fault in ("mkdir", "chmod") and args[0] == fault:
        sys.exit(1)
    sys.exit(subprocess.call(args))
elif cmd == "adb":
    if "getprop" in args:
        print("1")
elif cmd == "cp":
    if fault == "copy":
        Path(args[-1]).mkdir()
        (Path(args[-1]) / "partial").write_text("incomplete")
        sys.exit(1)
    sys.exit(subprocess.call(["/usr/bin/cp", *args]))
elif cmd == "mv":
    if fault == "swap" and args[-2].endswith("/data") and args[-1] == str(root / "data"):
        sys.exit(1)
    sys.exit(subprocess.call(["/usr/bin/mv", *args]))
else:
    sys.exit("unexpected command: " + cmd)
'''


class SnapshotTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="redroid-snapshot-test-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        shutil.copy2(REPO / "redroid.sh", self.root)
        shutil.copytree(REPO / "lib", self.root / "lib")
        config = (REPO / "redroid.env").read_text()
        config += "\nREDROID_DATA_DIR={}\nSNAPSHOT_DIR={}\nBOOT_TIMEOUT=1\n".format(
            shlex.quote(str(self.root / "data")),
            shlex.quote(str(self.root / "snapshots")),
        )
        (self.root / "redroid.env").write_text(config)
        (self.root / ".runtime").mkdir()
        (self.root / ".runtime/state.env").write_text("BT_MANAGED=0\n")
        self.data = self.root / "data"
        self.data.mkdir()
        (self.data / "app").write_text("clean")
        (self.data / ".settings").write_text("hidden")
        (self.data / "app").chmod(0o640)
        (self.data / "link").symlink_to("app")
        os.link(self.data / "app", self.data / "hardlink")
        self.bin = self.root / "bin"
        self.bin.mkdir()
        for name in ("docker", "sudo", "adb", "cp", "mv"):
            stub = self.bin / name
            stub.write_text(FAKE_COMMAND)
            stub.chmod(0o755)
        self.env = dict(os.environ, PATH=f"{self.bin}:{os.environ['PATH']}",
                        SNAPSHOT_TEST_ROOT=str(self.root))
        self.env.pop("REDROID_CONFIG", None)
        self.state("running")

    def state(self, status, **extra):
        (self.root / "container.json").write_text(json.dumps(dict(status=status, **extra)))

    def run_snapshot(self, action, name="clean", fault="", ok=True):
        result = subprocess.run(
            ["bash", str(self.root / "redroid.sh"), "snapshot", action, name],
            env=dict(self.env, SNAPSHOT_TEST_FAULT=fault), capture_output=True, text=True,
            timeout=10,
        )
        self.assertEqual(result.returncode == 0, ok, result.stdout + result.stderr)
        return result

    def events(self):
        path = self.root / "events"
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def run_reset(self, *args, fault="", ok=True):
        result = subprocess.run(
            ["bash", str(self.root / "redroid.sh"), "reset", *args],
            env=dict(self.env, SNAPSHOT_TEST_FAULT=fault), capture_output=True, text=True,
            timeout=10,
        )
        self.assertEqual(result.returncode == 0, ok, result.stdout + result.stderr)
        return result

    def assert_status(self, status):
        self.assertEqual(json.loads((self.root / "container.json").read_text())["status"], status)

    def test_round_trip_replaces_data_and_preserves_metadata(self):
        self.run_snapshot("save")
        (self.data / "app").write_text("dirty")
        (self.data / "extra").write_text("remove on restore")
        self.run_snapshot("restore")
        self.assertEqual((self.data / "app").read_text(), "clean")
        self.assertEqual((self.data / ".settings").read_text(), "hidden")
        self.assertEqual((self.data / "app").stat().st_mode & 0o777, 0o640)
        self.assertEqual((self.data / "link").readlink(), Path("app"))
        self.assertEqual((self.data / "app").stat().st_ino, (self.data / "hardlink").stat().st_ino)
        self.assertFalse((self.data / "extra").exists())
        self.assertFalse(list(self.root.glob(".redroid-restore.*")))
        self.assertEqual((self.root / "snapshots/clean").stat().st_mode & 0o777, 0o700)
        self.assert_status("running")
        events = self.events()
        for index, event in enumerate(events):
            if event[0] == "cp":
                self.assertTrue(any(e[:2] == ["docker", "stop"] for e in events[:index]))
        self.assertEqual((self.root / ".runtime/state.env").read_text(), "BT_MANAGED=0\n")

    def test_reset_requires_explicit_confirmation_before_host_commands(self):
        for args in ((), ("--force",), ("--yes", "extra")):
            with self.subTest(args=args):
                result = self.run_reset(*args, ok=False)
                self.assertIn("reset --yes", result.stderr)
        self.assertEqual(self.events(), [])
        self.assertEqual((self.data / "app").read_text(), "clean")

    def test_reset_empties_data_and_preserves_snapshots_and_external_files(self):
        self.run_snapshot("save")
        (self.root / "events").write_text("")
        self.data.chmod(0o750)
        before = self.data.stat()
        outside = self.root / "outside"
        outside.write_text("keep")
        (self.data / "external").symlink_to(outside)
        self.run_reset("--yes")
        self.assertEqual(list(self.data.iterdir()), [])
        self.assertEqual(self.data.stat().st_mode & 0o777, 0o750)
        self.assertEqual((self.data.stat().st_uid, self.data.stat().st_gid), (before.st_uid, before.st_gid))
        self.assertEqual(outside.read_text(), "keep")
        self.assertEqual((self.root / "snapshots/clean/data/app").read_text(), "clean")
        self.assertFalse(list(self.root.glob(".redroid-restore.*")))
        self.assert_status("running")
        self.assertEqual([e[1] for e in self.events() if e[:2] in
                          (["docker", "start"], ["docker", "stop"])], ["stop", "start"])
        self.assertEqual((self.root / ".runtime/state.env").read_text(), "BT_MANAGED=0\n")

    def test_reset_offline_leaves_the_container_stopped_or_absent(self):
        for status in ("absent", "exited", "created"):
            with self.subTest(status=status):
                self.state(status)
                (self.data / "app").write_text("dirty")
                self.run_reset("--yes")
                self.assertEqual(list(self.data.iterdir()), [])
                self.assert_status(status)
        self.assertFalse(any(e[:2] in (["docker", "start"], ["docker", "stop"]) for e in self.events()))

    def test_reset_preparation_and_swap_failures_preserve_current_data(self):
        for fault in ("mkdir", "chmod", "swap"):
            with self.subTest(fault=fault):
                self.run_reset("--yes", fault=fault, ok=False)
                self.assertEqual((self.data / "app").read_text(), "clean")
                self.assertFalse(list(self.root.glob(".redroid-restore.*")))
                self.assert_status("running")

    def test_reset_restart_failure_retains_previous_data(self):
        result = self.run_reset("--yes", fault="start", ok=False)
        backup, = self.root.glob(".redroid-restore.*/previous/app")
        self.assertEqual(backup.read_text(), "clean")
        self.assertEqual(list(self.data.iterdir()), [])
        self.assertIn("previous Android data retained", result.stderr)
        self.assert_status("exited")

    def test_reset_rejects_unsafe_paths_and_mounts_before_stop(self):
        self.state("running", mount=str(self.root))
        self.run_reset("--yes", ok=False)
        self.state("running")
        for path in ("/", str(self.root)):
            with (self.root / "redroid.env").open("a") as config:
                config.write(f"\nREDROID_DATA_DIR={shlex.quote(path)}\n")
            self.run_reset("--yes", ok=False)
        self.assertFalse(any(e[:2] == ["docker", "stop"] for e in self.events()))

    def test_reset_stop_failure_never_replaces_data(self):
        for fault in ("stop", "still-running"):
            self.run_reset("--yes", fault=fault, ok=False)
        self.assertEqual((self.data / "app").read_text(), "clean")
        self.assertFalse(any(e[0] == "mv" for e in self.events()))

    def test_reset_cannot_erase_the_toolbox_through_a_symlink(self):
        alias = self.root / "alias"
        alias.symlink_to(self.root, target_is_directory=True)
        self.state("running", mount=str(self.root))
        with (self.root / "redroid.env").open("a") as config:
            config.write(f"\nREDROID_DATA_DIR={shlex.quote(str(self.root))}\n")
        result = subprocess.run(["bash", str(alias / "redroid.sh"), "reset", "--yes"],
                                env=self.env, capture_output=True, text=True, timeout=10)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("must not contain the toolbox", result.stderr)
        self.assertFalse(any(e[:2] == ["docker", "stop"] for e in self.events()))

    def test_reset_stops_capture_before_stopping_android_and_replacing_data(self):
        session = self.root / "captures/session"
        session.mkdir(parents=True)
        (session / "proxy").write_text("172.17.0.1:8080")
        current = self.root / ".runtime/capture.current"
        current.write_text(str(session))
        self.run_reset("--yes")
        events = self.events()
        clear_proxy = next(i for i, e in enumerate(events) if "http_proxy" in e)
        stop = next(i for i, e in enumerate(events) if e[:2] == ["docker", "stop"])
        swap = next(i for i, e in enumerate(events) if e[0] == "mv")
        self.assertLess(clear_proxy, stop)
        self.assertLess(stop, swap)
        self.assertFalse(current.exists())
        self.assertTrue(session.exists())

    def test_reset_lock_contention_does_not_touch_data(self):
        with (self.root / ".runtime/lock").open("w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.run_reset("--yes", ok=False)
        self.assertEqual(self.events(), [])
        self.assertEqual((self.data / "app").read_text(), "clean")

    def test_offline_snapshots_do_not_start_a_container(self):
        for status in ("absent", "exited", "created"):
            with self.subTest(status=status):
                self.state(status)
                self.run_snapshot("save", status)
                self.run_snapshot("restore", status)
                self.assert_status(status)
        self.assertFalse(any(e[:2] in (["docker", "start"], ["docker", "stop"]) for e in self.events()))

    def test_invalid_or_duplicate_names_and_missing_restore_do_not_stop(self):
        for name in ("../escape", ".", "with space", "-option", "a" * 65):
            self.run_snapshot("save", name, ok=False)
        self.run_snapshot("restore", ok=False)
        self.run_snapshot("save")
        (self.root / "events").write_text("")
        self.run_snapshot("save", ok=False)
        self.assertFalse(any(e[:2] == ["docker", "stop"] for e in self.events()))

    def test_copy_failure_restarts_and_never_publishes_partial_snapshot(self):
        self.run_snapshot("save", fault="copy", ok=False)
        self.assertEqual(list((self.root / "snapshots").iterdir()), [])
        self.assertEqual((self.data / "app").read_text(), "clean")
        self.assert_status("running")

    def test_restore_copy_or_swap_failure_preserves_current_data(self):
        self.run_snapshot("save")
        (self.data / "app").write_text("current")
        for fault in ("copy", "swap"):
            with self.subTest(fault=fault):
                self.run_snapshot("restore", fault=fault, ok=False)
                self.assertEqual((self.data / "app").read_text(), "current")
                self.assertFalse(list(self.root.glob(".redroid-restore.*")))
                self.assert_status("running")

    def test_stop_failure_does_not_copy(self):
        for fault in ("stop", "still-running"):
            self.run_snapshot("save", fault=fault, ok=False)
        self.assertFalse(any(e[0] == "cp" for e in self.events()))
        self.assert_status("running")

    def test_restart_failure_keeps_previous_data(self):
        self.run_snapshot("save")
        (self.data / "app").write_text("current")
        result = self.run_snapshot("restore", fault="start", ok=False)
        backup, = self.root.glob(".redroid-restore.*/previous/app")
        self.assertEqual(backup.read_text(), "current")
        self.assertEqual((self.data / "app").read_text(), "clean")
        self.assertIn("./redroid.sh stop", result.stderr)
        self.assert_status("exited")

    def test_unsafe_container_or_paths_are_rejected_before_stop(self):
        for status in ("paused", "restarting", "dead"):
            self.state(status)
            self.run_snapshot("save", ok=False)
        self.state("running", mount=str(self.root))
        self.run_snapshot("save", ok=False)
        self.state("running")
        with (self.root / "redroid.env").open("a") as config:
            config.write("\nSNAPSHOT_DIR=./data/nested\n")
        self.run_snapshot("save", ok=False)
        self.assertFalse(any(e[:2] == ["docker", "stop"] for e in self.events()))

    def test_capture_stops_and_clears_proxy_before_android_stops(self):
        session = self.root / "captures/session"
        session.mkdir(parents=True)
        (session / "proxy").write_text("172.17.0.1:8080")
        current = self.root / ".runtime/capture.current"
        current.write_text(str(session))
        self.run_snapshot("save")
        events = self.events()
        clear_proxy = next(i for i, e in enumerate(events) if "http_proxy" in e)
        stop = next(i for i, e in enumerate(events) if e[:2] == ["docker", "stop"])
        self.assertLess(clear_proxy, stop)
        self.assertFalse(current.exists())
        self.assertTrue(session.exists())

    def test_lock_contention_has_no_host_effects(self):
        with (self.root / ".runtime/lock").open("w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.run_snapshot("save", ok=False)
        self.assertEqual(self.events(), [])

    def test_existing_local_config_uses_shipped_snapshot_default(self):
        config = self.root / "old.local.env"
        config.write_text("\n".join(
            line for line in (self.root / "redroid.env").read_text().splitlines()
            if not line.startswith("SNAPSHOT_DIR=")
        ))
        self.env["REDROID_CONFIG"] = str(config)
        self.run_snapshot("save")
        self.assertEqual((self.root / "snapshots/clean/data/app").read_text(), "clean")

    def test_boot_timeout_retains_previous_data(self):
        self.run_snapshot("save")
        (self.data / "app").write_text("current")
        with (self.root / "redroid.env").open("a") as config:
            config.write("\nBOOT_TIMEOUT=0\n")
        self.run_snapshot("restore", ok=False)
        backup, = self.root.glob(".redroid-restore.*/previous/app")
        self.assertEqual(backup.read_text(), "current")
        self.assertEqual((self.data / "app").read_text(), "clean")

    def test_symlink_snapshots_and_unavailable_daemon_are_rejected(self):
        self.run_snapshot("save", fault="daemon", ok=False)
        self.run_snapshot("save", fault="list", ok=False)
        snapshots = self.root / "snapshots"
        snapshots.mkdir()
        (snapshots / "linked").symlink_to(self.data, target_is_directory=True)
        (snapshots / "clean").mkdir()
        (snapshots / "clean/data").symlink_to(self.data, target_is_directory=True)
        self.run_snapshot("restore", ok=False)
        self.run_snapshot("restore", "linked", ok=False)
        self.assertFalse(any(e[:2] == ["docker", "stop"] for e in self.events()))


if __name__ == "__main__":
    unittest.main()
