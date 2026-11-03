#!/usr/bin/env python3
"""ADB guard tests with real nftables inside an unprivileged user+network namespace.

A nested namespace plays a LAN neighbour. A Docker-style DNAT rewrites the ADB
port before routing, so the guard must drop in prerouting, before NAT. The host
firewall is never touched; the tests skip when user namespaces or nft are missing.
"""
from pathlib import Path
import shutil
import subprocess
import tempfile
import textwrap
import unittest

REPO = Path(__file__).resolve().parents[1]

SCENARIO = r'''
set -euo pipefail
SCRIPT_DIR=$REPO
source "$REPO/lib/common.sh"
source "$REPO/lib/lifecycle.sh"
sudo() { "$@"; }
NFT_TABLE=redroid_guard ADB_PORT=5555
probe() {  # probe <namespace pid> <address>: prints open or blocked
    nsenter -t "$1" -n python3 -c '
import socket, sys
try:
    socket.create_connection((sys.argv[1], 5555), timeout=1).close(); print("open")
except OSError:
    print("blocked")' "$2"
}
unshare -n sleep 30 & lan=$!
sleep 0.3
ip link set lo up
ip link add v0 type veth peer name v1 netns "$lan"
ip addr add 10.9.0.1/24 dev v0 && ip link set v0 up
nsenter -t "$lan" -n sh -c 'ip addr add 10.9.0.2/24 dev v1; ip link set v1 up; ip link set lo up'
# Docker-style publish: the ADB port is DNATed to a backend on another port.
nft -f - <<EOF
add table ip docker_like
add chain ip docker_like pre { type nat hook prerouting priority dstnat; }
add rule ip docker_like pre tcp dport 5555 dnat to 10.9.0.1:6000
EOF
python3 -c '
import socket, threading
for port in (5555, 6000):
    s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("0.0.0.0", port)); s.listen()
    threading.Thread(target=lambda s=s: [s.accept()[0].close() for _ in iter(int, 1)], daemon=True).start()
import time; time.sleep(30)' & sleep 0.5
echo "lan-before=$(probe "$lan" 10.9.0.1)"
install_adb_guard >/dev/null
echo "lan-guarded=$(probe "$lan" 10.9.0.1)"
echo "loopback-guarded=$(probe $$ 127.0.0.1)"
remove_adb_guard
echo "removed=$(nft list table inet redroid_guard >/dev/null 2>&1 && echo no || echo yes)"
nft add table inet redroid_guard
remove_adb_guard 2>/dev/null
echo "foreign-kept=$(nft list table inet redroid_guard >/dev/null 2>&1 && echo yes || echo no)"
kill "$lan" %2 2>/dev/null || true
'''


class AdbGuardTests(unittest.TestCase):
    def test_guard_blocks_lan_before_dnat_and_only_removes_its_own_table(self):
        for tool in ("unshare", "nsenter", "nft", "ip"):
            if not shutil.which(tool):
                self.skipTest(f"{tool} is unavailable")
        if subprocess.run(["unshare", "-rn", "nft", "list", "ruleset"],
                          capture_output=True).returncode != 0:
            self.skipTest("unprivileged user namespaces with nftables are unavailable")
        with tempfile.TemporaryDirectory() as tmp:
            script = Path(tmp) / "scenario.sh"
            script.write_text(SCENARIO.replace("$REPO", str(REPO)))
            result = subprocess.run(["unshare", "-rn", "bash", str(script)],
                                    capture_output=True, text=True, timeout=60)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        seen = dict(line.split("=", 1) for line in result.stdout.split() if "=" in line)
        self.assertEqual(seen, {
            "lan-before": "open",
            "lan-guarded": "blocked",
            "loopback-guarded": "open",
            "removed": "yes",
            "foreign-kept": "yes",
        }, textwrap.indent(result.stdout + result.stderr, "  "))


if __name__ == "__main__":
    unittest.main()
