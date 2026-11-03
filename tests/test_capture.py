#!/usr/bin/env python3
"""Capture lifecycle tests with fake Docker, sudo, namespaces and network tools."""
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[1]
FAKE_COMMAND = f"#!{sys.executable}\n" + r'''
import ctypes
import json
import os
from pathlib import Path
import shlex
import signal
import sys
import time

root = Path(os.environ["CAPTURE_TEST_ROOT"])
cmd = Path(sys.argv[0]).name
args = sys.argv[1:]
fault = os.environ.get("CAPTURE_TEST_FAULT", "")
state_path = root / "guest.json"
def state():
    return json.loads(state_path.read_text())
def save(value):
    state_path.write_text(json.dumps(value))
with (root / "events").open("a") as log:
    log.write(json.dumps([cmd, *args]) + "\n")
if cmd == "sudo":
    if args == ["-v"]:
        sys.exit(0)
    os.execvp(args[0], args)
if cmd == "id":
    print("1000" if args == ["-u"] else "tester")
elif cmd == "sleep":
    time.sleep(0.3 if args == ["2"] else 0.02)
elif cmd == "docker":
    fmt = args[2]
    print(("false" if fault == "offline" else "true") if ".Running" in fmt else "12345" if ".Pid" in fmt else "172.17.0.1")
elif cmd == "stat":
    if args[-1] == "/proc/1/ns/net" or fault == "host-netns":
        print("100")
    elif args[-1] == "/proc/self/ns/net":
        print(os.environ.get("CAPTURE_TEST_NS", "100"))
    else:
        print("200")
elif cmd == "lsns":
    if fault != "gone":
        print("200 12345")
elif cmd == "nsenter":
    os.environ["CAPTURE_TEST_NS"] = "100" if fault == "pid-reused" else "200"
    os.execvp(args[3], args[3:])
elif cmd == "setpriv":
    assert "--regid" in args and args[args.index("--regid") + 1] == "2147483647", args
    assert "--no-new-privs" in args and "--bounding-set=-all" in args, args
    index = args.index("env")
    os.execvp(args[index], args[index:])
elif cmd in ("modprobe", "rmmod"):
    assert args == ["nft_redir"], args
elif cmd == "nft":
    assert os.environ.get("CAPTURE_TEST_NS") == "200", "host firewall accessed"
    value = state()
    if args == ["list", "tables"]:
        if value.get("table"):
            print("table inet " + value["table"])
    elif args[:2] == ["list", "table"]:
        print(value["rules"])
    elif args == ["-f", "-"]:
        rules = sys.stdin.read()
        if fault == "install":
            sys.exit(1)
        assert "create table inet redroid_capture" in rules
        assert "meta skgid 2147483647 return" in rules
        assert "ip daddr 127.0.0.0/8 return" in rules
        assert "ip6 daddr ::1 return" in rules
        assert "tcp dport { 80, 443 } redirect to :" in rules
        value.update(table="redroid_capture", rules=rules)
        save(value)
    elif args[:2] == ["delete", "table"]:
        if fault == "delete":
            sys.exit(1)
        value.pop("table", None)
        value.pop("rules", None)
        save(value)
    else:
        sys.exit("unexpected nft command: " + repr(args))
elif cmd == "adb":
    if args[0] == "connect" or "push" in args:
        sys.exit(0)
    shell = shlex.split(" ".join(args[3:]))
    if shell[:3] == ["settings", "get", "global"]:
        print(state()["proxy"])
    elif shell[:3] == ["settings", "put", "global"]:
        if fault in ("restore", "offline") and shell[4] != ":0":
            sys.exit(1)
        value = state()
        value["proxy"] = shell[4]
        save(value)
    elif shell[:3] == ["settings", "delete", "global"]:
        value = state()
        value["proxy"] = "null"
        save(value)
elif cmd == "openssl":
    print("12345678")
elif cmd in ("tcpdump", "mitmdump"):
    if cmd == "mitmdump" and fault == "proxy":
        sys.exit(1)
    if cmd == "mitmdump" and fault == "port" and any("8080" in a for a in args):
        print("Address already in use", file=sys.stderr)
        sys.exit(1)
    ctypes.CDLL(None).prctl(15, cmd.encode(), 0, 0, 0)
    with (root / "workers").open("a") as log:
        log.write(str(os.getpid()) + "\n")
    target = args[args.index("-w") + 1]
    Path(target).write_text("captured")
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    signal.signal(signal.SIGINT, lambda *_: sys.exit(0))
    while True:
        time.sleep(0.02)
else:
    sys.exit("unexpected mock command: " + cmd)
'''


class CaptureTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="redroid-capture-test-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.addCleanup(self.stop_workers)
        shutil.copy2(REPO / "redroid.sh", self.root)
        shutil.copytree(REPO / "lib", self.root / "lib")
        shutil.copy2(REPO / "redroid.env", self.root)
        (self.root / "guest.json").write_text(json.dumps({"proxy": "old.proxy:8888"}))
        self.bin = self.root / "bin"
        self.bin.mkdir()
        for name in ("bash", "sh", "env", "dirname", "mkdir", "flock", "tr", "date", "mktemp",
                     "cat", "grep", "awk", "rm", "find", "timeout", "kill"):
            (self.bin / name).symlink_to(shutil.which(name))
        for name in ("sudo", "id", "sleep", "docker", "stat", "lsns", "nsenter", "setpriv",
                     "nft", "adb", "openssl", "tcpdump", "mitmdump", "modprobe", "rmmod"):
            command = self.bin / name
            command.write_text(FAKE_COMMAND)
            command.chmod(0o755)
        self.env = dict(os.environ, PATH=str(self.bin), HOME=str(self.root), CAPTURE_TEST_ROOT=str(self.root))
        self.env.pop("REDROID_CONFIG", None)
        (self.root / ".mitmproxy").mkdir()
        (self.root / ".mitmproxy/mitmproxy-ca-cert.pem").write_text("test CA")

    def stop_workers(self):
        workers = self.root / "workers"
        if workers.exists():
            for pid in workers.read_text().splitlines():
                try:
                    environ = Path(f"/proc/{pid}/environ").read_bytes()
                    if f"CAPTURE_TEST_ROOT={self.root}".encode() in environ:
                        os.kill(int(pid), signal.SIGTERM)
                except (FileNotFoundError, ProcessLookupError, PermissionError):
                    pass

    def run_capture(self, *args, fault="", ok=True):
        result = subprocess.run(
            [str(self.bin / "bash"), str(self.root / "redroid.sh"), "capture", *args],
            env=dict(self.env, CAPTURE_TEST_FAULT=fault), capture_output=True, text=True, timeout=15,
        )
        self.assertEqual(result.returncode == 0, ok, result.stdout + result.stderr)
        return result

    def state(self):
        return json.loads((self.root / "guest.json").read_text())

    def events(self):
        return [json.loads(line) for line in (self.root / "events").read_text().splitlines()]

    def session(self):
        return Path((self.root / ".runtime/capture.current").read_text().strip())

    def test_transparent_round_trip_restores_proxy_and_only_owns_one_table(self):
        self.run_capture("start", "--transparent")
        session = self.session()
        self.assertEqual(self.state()["proxy"], ":0")
        self.assertEqual(self.state()["table"], "redroid_capture")
        self.assertEqual(session.stat().st_mode & 0o777, 0o700)
        proxy = next(e for e in self.events() if e[0] == "mitmdump")
        self.assertIn("transparent@127.0.0.1:8080", proxy)
        self.assertIn("transparent@::1:8080", proxy)
        self.run_capture("stop")
        self.assertEqual(self.state(), {"proxy": "old.proxy:8888"})
        self.assertFalse((self.root / ".runtime/capture.current").exists())
        self.assertFalse((session / "redirect.table").exists())
        self.assertTrue((session / "full.pcap").exists())
        self.assertTrue((session / "flows.mitm").exists())

    def test_regular_and_raw_modes_remain_available(self):
        for flags in ((), ("--no-mitm",)):
            self.run_capture("start", *flags)
            self.assertNotIn("table", self.state())
            self.run_capture("stop")
            self.assertEqual(self.state()["proxy"], "old.proxy:8888")

    def test_install_failure_rolls_back_proxy_and_processes(self):
        self.run_capture("start", "--transparent", fault="install", ok=False)
        self.assertEqual(self.state(), {"proxy": "old.proxy:8888"})
        self.assertFalse((self.root / ".runtime/capture.current").exists())

    def test_delete_failure_keeps_recovery_metadata_and_proxy_alive(self):
        self.run_capture("start", "--transparent")
        session = self.session()
        self.run_capture("stop", fault="delete", ok=False)
        self.assertEqual(self.session(), session)
        self.assertTrue((session / "mitm.pid").exists())
        self.assertIn("table", self.state())
        self.run_capture("stop")
        self.assertEqual(self.state(), {"proxy": "old.proxy:8888"})

    def test_proxy_restore_failure_can_be_retried_after_redirect_removal(self):
        self.run_capture("start", "--transparent")
        self.run_capture("stop", fault="restore", ok=False)
        self.assertNotIn("table", self.state())
        self.assertTrue((self.root / ".runtime/capture.current").exists())
        self.run_capture("stop")
        self.assertEqual(self.state()["proxy"], "old.proxy:8888")

    def test_existing_table_is_not_deleted(self):
        (self.root / "guest.json").write_text(json.dumps({"proxy": "null", "table": "redroid_capture", "rules": "foreign"}))
        self.run_capture("start", "--transparent", ok=False)
        self.assertEqual(self.state(), {"proxy": "null", "table": "redroid_capture", "rules": "foreign"})

    def test_host_namespace_and_pid_reuse_are_rejected(self):
        self.run_capture("start", "--transparent", fault="host-netns", ok=False)
        self.run_capture("start", "--transparent", fault="pid-reused", ok=False)
        self.assertFalse(any(e[0] == "nft" for e in self.events()))

    def test_changed_table_owner_is_preserved(self):
        self.run_capture("start", "--transparent")
        value = self.state()
        value["rules"] = "foreign"
        (self.root / "guest.json").write_text(json.dumps(value))
        self.run_capture("stop", ok=False)
        self.assertEqual(self.state()["rules"], "foreign")

    def test_proxy_start_failure_rolls_back_and_port_conflicts_retry(self):
        self.run_capture("start", "--transparent", fault="proxy", ok=False)
        self.assertFalse((self.root / ".runtime/capture.current").exists())
        self.run_capture("start", "--transparent", fault="port")
        self.assertIn("redirect to :8081", self.state()["rules"])
        self.run_capture("stop")

    def test_invalid_flag_combinations_are_rejected(self):
        self.run_capture("start", "--no-mitm", "--transparent", ok=False)
        self.assertFalse((self.root / ".runtime/capture.current").exists())

    def test_proxy_crash_still_removes_redirect(self):
        self.run_capture("start", "--transparent")
        pid = int((self.session() / "mitm.pid").read_text())
        os.kill(pid, signal.SIGTERM)
        self.run_capture("stop")
        self.assertNotIn("table", self.state())

    def test_stop_uses_saved_table_even_after_config_change(self):
        self.run_capture("start", "--transparent")
        with (self.root / "redroid.env").open("a") as config:
            config.write("\nCAPTURE_NFT_TABLE=renamed_capture\n")
        self.run_capture("stop")
        self.assertNotIn("table", self.state())

    def test_missing_namespace_is_safe_to_clean(self):
        self.run_capture("start", "--transparent")
        self.run_capture("stop", fault="gone")
        self.assertFalse((self.root / ".runtime/capture.current").exists())
        self.assertFalse(any(e[:3] == ["nft", "delete", "table"] for e in self.events()))

    def test_offline_guest_does_not_block_host_cleanup(self):
        self.run_capture("start", "--transparent")
        session = self.session()
        result = self.run_capture("stop", fault="offline")
        self.assertNotIn("table", self.state())
        self.assertFalse((self.root / ".runtime/capture.current").exists())
        self.assertTrue((session / "proxy.before").exists())
        self.assertIn("manual recovery", result.stderr)


if __name__ == "__main__":
    unittest.main()
