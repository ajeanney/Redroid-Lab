# Redroid-Lab

Toolbox around a pinned Android 14 [redroid](https://github.com/remote-android/redroid-doc) container on an x86_64 Linux host. Today it provides optional physical Bluetooth passthrough (AOSP Linux-HCI HAL), GPU acceleration, scrcpy, ARM64 translation, APK install/pull with optional static analysis, Android data snapshots, packet capture (tcpdump + mitmproxy) and root-based app investigation (Frida, SSL-pinning bypass). Human docs: [README.md](README.md), [README.fr.md](README.fr.md).

## Local instructions (read first)

If `AGENTS.local.md` (or any `*.local.md` at the repo root) exists, read it before doing anything else. It holds machine-specific agent instructions, is gitignored, and takes precedence over this file on conflict. Never commit it or copy its contents into tracked files.

## Safety first (host-impacting project)

`./redroid.sh start` stops and runtime-masks BlueZ, powers down `hci0`, starts a **privileged** container, and installs an nftables guard. `stop` reverses this. `start --no-bt` (or `BT_ENABLE=0`) skips every Bluetooth step and the host-netns mount; the state file records `BT_MANAGED` so `stop` only restores what was taken. `capture start` runs `tcpdump` through `sudo`+`nsenter`, runs `mitmdump` on the Docker gateway, writes the mitmproxy CA into the guest and temporarily changes its global `http_proxy`; `capture start --transparent` instead runs a restricted proxy inside the guest netns and installs a session-owned nftables redirect for TCP/80,443; `capture stop` (also run by `stop`) undoes all of it. `frida start` pushes and runs `frida-server` as **root in the guest** and forwards its port to the host loopback; `frida unpin` spawns an app with its SSL-pinning checks patched out so `capture` can decode it. Treat these as host-changing operations.

Allowed without asking:
- Read any file; `git status`, `git diff`, `git log`
- `bash -n redroid.sh lib/*.sh build/*.sh`, `shellcheck redroid.sh lib/*.sh build/*.sh`
- `./redroid.sh status` (read-only)

Ask first:
- `./redroid.sh setup | start | stop | screen | logs | install | pull | launch | snapshot | capture | frida | appdata` (installs packages, builds images, takes over Bluetooth, writes `.runtime/`, `apps/`, `appdata/`, `snapshots/`, `captures/` and `.cache/frida/`; snapshot restore replaces Android data)
- Any `docker`, `systemctl`, `bluetoothctl`, `btmgmt`, `nft`, `modprobe` or `sudo` command
- `git commit`, `git push`, deleting files, adding dependencies or changing pinned digests/checksums

Never:
- Run `systemctl start bluetooth` or touch `hci0` by hand while `.runtime/state.env` exists; the script owns recovery (use `./redroid.sh stop`, with approval)
- Loosen the `ADB_HOST` loopback-only check or publish ADB on a non-loopback address
- Commit `data/`, `apps/`, `appdata/`, `snapshots/`, `.redroid-restore.*/`, `.runtime/`, `.cache/`, `captures/`, APKs, keystores, logs, Bluetooth bonds or any `*.local.*` file
- Put secrets, tokens or personal data in tracked files, including this one

## Layout

| Path | Purpose |
| --- | --- |
| `redroid.sh` | Single entry point: `setup`, `start`, `stop`, `screen`, `status`, `logs`, `install`, `pull`, `launch`, `snapshot`, `capture`, `frida`, `appdata`. Defines paths, sources `lib/`, dispatches. Lifecycle under a lock, state in `.runtime/state.env`, active capture in `.runtime/capture.current` |
| `lib/` | Sourced by `redroid.sh`, one area per file: `common.sh` (messages, config, lock, Docker/ADB wrappers), `setup.sh`, `bluetooth.sh` (host takeover/restore), `lifecycle.sh` (`start`/`stop`/`screen`/`status`/`logs`, host state), `capture.sh`, `apps.sh` (`install`/`pull`/`launch`, optional `--report` via `manifest_report.py`), `appdata.sh` (private live copies/diffs via `appdata.py`), `snapshot.sh`, `frida.sh`. Keep each under ~600 lines |
| `.shellcheckrc` | Lets `shellcheck redroid.sh` follow the sourced `lib/` files |
| `redroid.env` | Defaults (image, ports, adapter, `BT_ENABLE`, APK/snapshot/capture directories, capture/Frida ports, transparent table/group, display, timeouts). Override via `REDROID_CONFIG=./redroid.local.env` |
| `apps/` | Gitignored pulls (`<package>/<UTC timestamp>-<random suffix>/`): APKs/splits plus optional `apktool/` and `jadx/` output; set `PULL_DIR` to override |
| `appdata/` | Gitignored private user-0 app data pulls; `appdata pull <package>` copies live data, `appdata diff <package>` compares the last two completed copies |
| `snapshots/` | Gitignored named copies of Android data (`<name>/data/`); `snapshot save\|restore <name>` stops the existing container and restarts it only if it was running |
| `.redroid-restore.*/` | Private restore staging next to the data directory; previous data retained on restart failure |
| `captures/` | Gitignored capture sessions (`full.pcap`, `flows.mitm`, `sslkeylog.txt`, `full-decrypted.pcapng`); optional timeline flags write UID logcat, a scrcpy recording, HCI snoop and clock anchors; proxied sessions also record `netns.id`, `redirect.table`, `module.loaded` and `proxy.before` for cleanup |
| `frida/` | `unpin.js` is the Java TLS bypass; `frida script <name> <package> [args]` selects crypto, conceal, native-unpin or flutter-unpin hooks |
| `.cache/frida/` | Gitignored: downloaded, checksummed `frida-server` binaries |
| `Dockerfile` | Overlay on the pinned redroid image; builds and installs the Bluetooth HAL |
| `build-inputs.env` | Pinned source URLs and SHA-256 sums for the HAL build, plus the pinned Frida version/checksum |
| `build/` | `build-bt-hal.sh` (also patches the HAL to read the HCI index from `ro.redroid.bt.hci`), `validate-runtime.sh`, `btlinux-service.cc`, the HAL `.rc`, `build-arm64-smoke-apk.sh` |
| `tests/arm64-smoke-app/` | Source of the ARM64-only JNI smoke APK installed and removed by `start` |
| `tests/test_adb_guard.py` | Real nftables ADB guard in an unprivileged user+network namespace: blocks a LAN neighbour before Docker-style DNAT, keeps loopback, removes only its own table (skips without user namespaces) |
| `tests/test_capture.py` | Isolated explicit/raw/transparent capture lifecycle and rollback tests with fake host tools |
| `tests/test_pull.py` | Isolated extraction, optional analysis and failure tests with fake ADB, apktool and jadx commands |
| `tests/test_snapshot.py` | Isolated snapshot round-trip and failure tests with fake Docker, sudo and ADB commands |

The `btlinux` name in HAL files, binaries and `redroid.sh` messages is AOSP's component name (`android.hardware.bluetooth@1.1-service.btlinux`), not the old project name. Do not rename it.

## Commands

File-scoped checks (preferred, no side effects):

```sh
bash -n redroid.sh lib/*.sh
shellcheck redroid.sh lib/*.sh   # also: shellcheck build/<file>.sh
git diff --check
python3 tests/test_adb_guard.py  # real nft inside `unshare -rn`; host firewall untouched
python3 tests/test_capture.py    # fake namespaces/firewall/processes; no root or network
node tests/test_frida_scripts.js # mocked Frida APIs, no guest or network
python3 tests/test_frida.py      # Frida script dispatch and package validation
python3 tests/test_manifest_report.py # decoded manifest and network security reports
python3 tests/test_appdata.py    # safe archive extraction and app-data diffs with fake guest commands
python3 tests/test_pull.py       # temporary files and fake ADB/analysis tools
python3 tests/test_snapshot.py   # temporary data and fake commands; no hardware or sudo
```

Both `bash -n` and `shellcheck` are clean today (rc 0); keep them clean.

Runtime verification (needs approval, real hardware, Binder-capable kernel):

```sh
./redroid.sh setup && ./redroid.sh start   # start fails closed and rolls back on any error
./redroid.sh status
./redroid.sh stop
./redroid.sh start --no-bt && ./redroid.sh capture start   # no Bluetooth hardware needed
```

Capture, pull and snapshot tests cover file operations and mocked command/lifecycle failures. Hardware-dependent changes can only be verified by a human on a machine with a supported controller; say so instead of claiming verification.

## Code style

- Background processes started by the script must close the lock fd (`9>&-`), and `adb` is wrapped to do so (`adb_timeout` for `timeout adb`): an inherited fd 9 keeps the lifecycle lock held forever
- Bash: `#!/usr/bin/env bash`, `set -Eeuo pipefail`, 4-space indent, quote every expansion, `[[ ]]` tests, `die`/`note`/`need` helpers for errors and progress
- Keep ShellCheck clean; justify any `# shellcheck disable=` inline
- Configuration belongs in `redroid.env` (add the key to the required-name list in `load_config` in `lib/common.sh`), never hardcoded in the script
- Reuse the helpers in `lib/common.sh` (`need a b c`, `warn`, `adb_dev`, `adb_connect`, `require_running`, `trap_exit`, `stamped_dir`) instead of repeating their bodies
- Transparent capture must verify namespace identity after entry, reject the host netns, and delete only its own table. Cleanup failures must retain capture state for retry; only unload `nft_redir` if this capture loaded it.
- Fail closed: every host mutation needs a matching restore path in `restore_host_state`/`rollback_start`, and `stop` must stay idempotent
- New tools (capture, root inspection, ...) go in separate subcommands with their own `lib/<area>.sh` (sourced from `redroid.sh`); do not grow `cmd_start` and do not weaken its validations
- Pin every downloaded input with a checksum in `build-inputs.env`; no floating tags or `latest`

Good pattern: `validate_adapter_identity` (`lib/bluetooth.sh`) and `restore_host_state` (`lib/lifecycle.sh`): explicit checks, clear errors, restore paths. Avoid: ad-hoc `sudo` calls outside the existing helpers.

## Docs and commits

- Keep `README.md` and `README.fr.md` in sync; update both when behavior, commands or config change. Update this file when commands or layout change
- Do not mark planned features as available in either README
- Commits: short imperative subject, one logical change each; do not push without approval
- Docker build context excludes `*.md`, `lib/`, `tests/`, `data/`, `.runtime/`; if the Dockerfile needs a new input, check `.dockerignore`

## When stuck

Ask a clarifying question rather than guessing about hardware, adapter IDs (`BT_EXPECTED_USB_ID`), or anything that touches host Bluetooth/network state. If a lifecycle command fails repeatedly, stop and report the output; do not retry in a loop.
