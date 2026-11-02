# Redroid-Lab

Toolbox around a pinned Android 14 [redroid](https://github.com/remote-android/redroid-doc) container on an x86_64 Linux host. Today it provides optional physical Bluetooth passthrough (AOSP Linux-HCI HAL), GPU acceleration, scrcpy, ARM64 translation, APK install and packet capture (tcpdump + mitmproxy). Planned (not implemented): root-based app investigation. Human docs: [README.md](README.md), [README.fr.md](README.fr.md).

## Local instructions (read first)

If `AGENTS.local.md` (or any `*.local.md` at the repo root) exists, read it before doing anything else. It holds machine-specific agent instructions, is gitignored, and takes precedence over this file on conflict. Never commit it or copy its contents into tracked files.

## Safety first (host-impacting project)

`./redroid.sh start` stops and runtime-masks BlueZ, powers down `hci0`, starts a **privileged** container, and installs an nftables guard. `stop` reverses this. `start --no-bt` (or `BT_ENABLE=0`) skips every Bluetooth step and the host-netns mount; the state file records `BT_MANAGED` so `stop` only restores what was taken. `capture start` runs `tcpdump` through `sudo`+`nsenter`, runs `mitmdump` on the Docker gateway, writes the mitmproxy CA into the guest and sets its global `http_proxy`; `capture stop` (also run by `stop`) undoes all of it. Treat these as host-changing operations.

Allowed without asking:
- Read any file; `git status`, `git diff`, `git log`
- `bash -n redroid.sh build/*.sh`, `shellcheck redroid.sh build/*.sh`
- `./redroid.sh status` (read-only)

Ask first:
- `./redroid.sh setup | start | stop | screen | logs | install | launch | capture` (installs packages, builds images, takes over Bluetooth, writes `.runtime/` and `captures/`)
- Any `docker`, `systemctl`, `bluetoothctl`, `btmgmt`, `nft`, `modprobe` or `sudo` command
- `git commit`, `git push`, deleting files, adding dependencies or changing pinned digests/checksums

Never:
- Run `systemctl start bluetooth` or touch `hci0` by hand while `.runtime/state.env` exists; the script owns recovery (use `./redroid.sh stop`, with approval)
- Loosen the `ADB_HOST` loopback-only check or publish ADB on a non-loopback address
- Commit `data/`, `.runtime/`, `.cache/`, `captures/`, APKs, keystores, logs, Bluetooth bonds or any `*.local.*` file
- Put secrets, tokens or personal data in tracked files, including this one

## Layout

| Path | Purpose |
| --- | --- |
| `redroid.sh` | Single entry point: `setup`, `start`, `stop`, `screen`, `status`, `logs`, `install`, `launch`, `capture`. Lifecycle under a lock, state in `.runtime/state.env`, active capture in `.runtime/capture.current` |
| `redroid.env` | Defaults (image, ports, adapter, `BT_ENABLE`, capture dir/port, display, timeouts). Override via `REDROID_CONFIG=./redroid.local.env` |
| `captures/` | Gitignored capture sessions (`full.pcap`, `flows.mitm`, `sslkeylog.txt`, `full-decrypted.pcapng`) |
| `Dockerfile` | Overlay on the pinned redroid image; builds and installs the Bluetooth HAL |
| `build-inputs.env` | Pinned source URLs and SHA-256 sums for the HAL build |
| `build/` | `build-bt-hal.sh` (also patches the HAL to read the HCI index from `ro.redroid.bt.hci`), `validate-runtime.sh`, `btlinux-service.cc`, the HAL `.rc`, `build-arm64-smoke-apk.sh` |
| `tests/arm64-smoke-app/` | Source of the ARM64-only JNI smoke APK installed and removed by `start` |

The `btlinux` name in HAL files, binaries and `redroid.sh` messages is AOSP's component name (`android.hardware.bluetooth@1.1-service.btlinux`), not the old project name. Do not rename it.

## Commands

File-scoped checks (preferred, no side effects):

```sh
bash -n redroid.sh
shellcheck redroid.sh            # also: shellcheck build/<file>.sh
git diff --check
```

Both `bash -n` and `shellcheck` are clean today (rc 0); keep them clean.

Runtime verification (needs approval, real hardware, Binder-capable kernel):

```sh
./redroid.sh setup && ./redroid.sh start   # start fails closed and rolls back on any error
./redroid.sh status
./redroid.sh stop
./redroid.sh start --no-bt && ./redroid.sh capture start   # no Bluetooth hardware needed
```

There is no automated test suite. Hardware-dependent changes can only be verified by a human on a machine with a supported controller; say so instead of claiming verification.

## Code style

- Background processes started by the script must close the lock fd (`9>&-`), and `adb` is wrapped to do so: an inherited fd 9 keeps the lifecycle lock held forever
- Bash: `#!/usr/bin/env bash`, `set -Eeuo pipefail`, 4-space indent, quote every expansion, `[[ ]]` tests, `die`/`note`/`need` helpers for errors and progress
- Keep ShellCheck clean; justify any `# shellcheck disable=` inline
- Configuration belongs in `redroid.env` (add the key to the required-name list in `load_config`), never hardcoded in the script
- Fail closed: every host mutation needs a matching restore path in `restore_host_state`/`rollback_start`, and `stop` must stay idempotent
- New tools (capture, root inspection, ...) go in separate subcommands or scripts; do not grow `cmd_start` and do not weaken its validations
- Pin every downloaded input with a checksum in `build-inputs.env`; no floating tags or `latest`

Good pattern: `validate_adapter_identity` and `restore_host_state` in `redroid.sh` (explicit checks, clear errors, restore paths). Avoid: ad-hoc `sudo` calls outside the existing helpers.

## Docs and commits

- Keep `README.md` and `README.fr.md` in sync; update both when behavior, commands or config change. Update this file when commands or layout change
- Do not mark planned features as available in either README
- Commits: short imperative subject, one logical change each; do not push without approval
- Docker build context excludes `*.md`, `tests/`, `data/`, `.runtime/`; if the Dockerfile needs a new input, check `.dockerignore`

## When stuck

Ask a clarifying question rather than guessing about hardware, adapter IDs (`BT_EXPECTED_USB_ID`), or anything that touches host Bluetooth/network state. If a lifecycle command fails repeatedly, stop and report the output; do not retry in a loop.
