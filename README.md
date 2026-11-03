# Redroid-Lab

A toolbox for running and investigating a pinned Android 14 [redroid](https://github.com/remote-android/redroid-doc) container on an x86_64 Linux host: persistent data, GPU acceleration, loopback-only ADB and scrcpy, ARM64 application translation, network packet capture, and (optionally) working access to a real physical Bluetooth controller.

The project started as a Bluetooth-passthrough image and is growing into a
general lab for poking at Android apps: packet capture, root-level app
inspection, and similar reverse-engineering workflows.

## Scope

| Capability | Status |
| --- | --- |
| Pinned redroid 14 image with persistent data, Intel GPU, scrcpy | Available |
| ARM64 application translation (`libndk_translation`) | Available |
| Physical Bluetooth passthrough (AOSP Linux-HCI HAL) | Available |
| Optional Bluetooth: run without it via `start --no-bt` | Available |
| Network packet capture (pcap + decoded HTTPS), transparent proxying and APK install | Available |
| Root-based app investigation: Frida hooking and SSL-pinning bypass | Available |
| Named snapshots of Android data for repeatable app states | Available |
| Pull installed APKs and splits, with optional apktool/jadx analysis | Available |

"Planned" rows are goals; none is implemented yet.

Contributors and AI coding agents: see [AGENTS.md](AGENTS.md).

## Physical Bluetooth

Bluetooth passthrough is optional: `./redroid.sh start --no-bt` (or
`BT_ENABLE=0` in the configuration) boots Android without touching BlueZ or the
adapter, so the container can be used for everything else, such as packet capture.

Physical Bluetooth is not supported by stock redroid: the upstream image uses
a simulated controller. Redroid-Lab replaces that simulation with AOSP's
small Linux-HCI (`btlinux`) HAL. The integration works on the reference machine,
but remains an out-of-tree, privileged configuration and should be evaluated
accordingly.

Upstream references:

- [redroid documentation and native-bridge support](https://github.com/remote-android/redroid-doc#native-bridge-support)
- [redroid physical-Bluetooth limitation](https://github.com/remote-android/redroid-doc/issues/353)
- [AOSP btlinux HCI implementation](https://android.googlesource.com/platform/system/bt/+/android-11.0.0_r48/vendor_libs/linux/interface/bluetooth_hci.cc)

## Validation status

| Platform | Validation performed | Status |
| --- | --- | --- |
| Arch Linux x86_64, Intel AX211 | Full build, Android boot, Intel GPU, scrcpy video/audio, ARM64-only JNI APK, real Bluetooth inquiry, and BlueZ restoration | Verified |
| Ubuntu 22.04 LTS | Clean installation of the complete host dependency set; Bash 5.1 syntax and command-path audit | Compatible; hardware run still required |
| Ubuntu 24.04 LTS | Clean installation of the complete host dependency set; Bash 5.2 syntax and command-path audit | Compatible; hardware run still required |
| Debian | Package mapping and Binder guidance are implemented | Best effort; not hardware-tested |
| Arch Linux x86_64, AMD Lucienne GPU, Realtek `0bda:2852` Bluetooth | Build, boot on the host GPU, ARM64 bridge properties, real Bluetooth inquiry that found nearby devices, BlueZ restoration, split-APK install, packet capture with decoded HTTPS from a real app | Verified |

The Ubuntu checks confirm that the setup's dependencies and shell interfaces
are available on both LTS releases. They cannot substitute for an end-to-end
test of a colleague's kernel, GPU, USB controller, and peripheral. Run the
preflight on each new host before relying on Bluetooth.

## Architecture

```text
Android framework and netd ── Docker bridge ── host networking
              │
              └─ btlinux HAL ── host network namespace ── HCI_CHANNEL_USER ── hci0

ADB/scrcpy ── 127.0.0.1:5555 only

capture: tcpdump (container netns) ── full.pcap
         mitmproxy (Docker gateway) ◄── Android global proxy ── flows.mitm
transparent: nftables OUTPUT redirect ── mitmproxy (container netns) ── flows.mitm
```

Android stays in Docker's network namespace, preventing `netd` from modifying
the host's physical interfaces or policy routes. Only the btlinux HAL enters
the host network namespace, which is necessary to open Linux Bluetooth HCI
sockets. The controller is exclusive: BlueZ and Android cannot own it at the
same time.

## Host requirements

- x86_64 Linux with systemd and Docker
- Binder IPC and BinderFS in the running kernel
- DRM render node at `/dev/dri/renderD128` (Intel is the reference; `setup` only warns on other vendors, and an AMD GPU boots in host mode; if yours does not, set `REDROID_GPU_MODE=guest` in a local config)
- for Bluetooth passthrough only: a controller exposed as `hciN` (any vendor; `btusb` for the reset fallback)
- for capture: `tcpdump`, `mitmproxy`, Wireshark's `editcap` and `nsenter`; `setup` installs them on Arch, Debian and Ubuntu, and `capture start` needs `sudo` for tcpdump
- for Frida: `curl` and `xz` (installed by `setup`); `frida unpin`/`exec` use `uv`'s `uvx` to run the matching host client unless one matching the pinned version is already installed
- for optional static analysis: host commands `apktool` and/or `jadx`, with their Java runtime; install them separately, as `setup` does not install them
- approximately 10 GB of free space for images, build inputs, and cache
- outbound HTTPS access during the initial build

The passthrough is adapter-agnostic: it uses the kernel's exclusive
`HCI_CHANNEL_USER` socket, so any controller that Linux exposes as `hciN`
should work, whatever its vendor (verified on an Intel AX211 and a Realtek
`0bda:2852`). Set `BT_ADAPTER` to the right index (default `hci0`; the HAL reads
it from a system property, so it need not be 0). To refuse anything but one
known controller, set `BT_EXPECTED_USB_ID` (for example `8087:0033`) in
`redroid.env`; it is empty by default. The adapter must already have its
firmware loaded, which BlueZ does when it powers the adapter at boot. Only one
adapter is passed through, and the guarded `btusb` reset fallback only applies
to USB controllers.

### Ubuntu 22.04 and 24.04

`./redroid.sh setup` installs missing packages from the standard Ubuntu
repositories. Before running it, enable Docker and grant the invoking user
access to the daemon:

```sh
sudo systemctl enable --now docker.service bluetooth.service
sudo usermod -aG docker "$USER"
```

Log out and back in after changing group membership. If `scrcpy` is not visible
in a customized/minimal Ubuntu installation, enable the Universe repository:

```sh
sudo apt install software-properties-common
sudo add-apt-repository universe
sudo apt update
```

Ubuntu normally supplies Binder through the running kernel's extra module
package. If setup reports that BinderFS is unavailable:

```sh
sudo apt install "linux-modules-extra-$(uname -r)"
sudo modprobe binder_linux devices=binder,hwbinder,vndbinder
grep binder /proc/filesystems
```

Do not switch kernels preemptively. Use the running kernel first and install a
different Binder-capable kernel only if the preflight proves it necessary.

### Arch Linux

The script installs missing packages with `pacman` and verifies Binder support
in the running kernel. Docker must be running and accessible to the invoking
user.

## Quick start

```sh
./redroid.sh setup
./redroid.sh start
./redroid.sh screen
```

Without Bluetooth (leaves BlueZ and the adapter alone):

```sh
./redroid.sh start --no-bt
```

Stop Android (and any running capture) and return the Bluetooth adapter to Linux with:

```sh
./redroid.sh stop
```

`start` is successful only after Android has booted, the physical HCI controller
is ready, Bluetooth reports `ON`, host network snapshots remain unchanged, and
the optional ARM64 smoke APK passes. Any startup failure removes the container
and restores the host's previous BlueZ and adapter power state.

## Command reference

| Command | Purpose |
| --- | --- |
| `./redroid.sh setup` | Install missing dependencies, build the pinned overlay image, and optionally build the ARM64 smoke APK |
| `./redroid.sh start [--no-bt]` | Reserve `hci0` (unless `--no-bt`), boot Android, and validate networking, Bluetooth, and ARM64 translation |
| `./redroid.sh stop` | End any capture, remove Android, and restore the previous BlueZ and adapter state |
| `./redroid.sh screen` | Open scrcpy; use AAC on modern releases and video/input-only mode on older Ubuntu packages |
| `./redroid.sh status` | Show container, Android, ABI, BlueZ, and btlinux readiness |
| `./redroid.sh logs` | Print Bluetooth diagnostics and save HCI snoop data when available |
| `./redroid.sh install <apk\|dir>...` | Install one APK, several split APKs, or a directory of splits (`base.apk` + `split_config.*.apk`) |
| `./redroid.sh pull <package> [--apktool] [--jadx] [--report]` | Extract installed APKs and splits; optionally decode resources/smali or decompile Java sources |
| `./redroid.sh launch <package>` | Start an installed app headlessly (then watch it with `screen`) |
| `./redroid.sh appdata pull\|diff <package>` | Copy private user-0 files or compare the last two completed pulls |
| `./redroid.sh snapshot save\|restore <name>` | Save or replace Android data while the container is stopped; restart it if it was running |
| `./redroid.sh capture start [--no-mitm\|--transparent] [--app <pkg>] [--logcat] [--record] [--btsnoop]` | Record all container traffic to `captures/<UTC timestamp>-<random suffix>/` |
| `./redroid.sh capture stop` / `status` | End the session and write the artifacts / show the active session |
| `./redroid.sh frida start` / `stop` | Push and run `frida-server` as root in the guest, forwarded to the host loopback / stop it |
| `./redroid.sh frida unpin <package>` | Spawn an app with Java-layer SSL-pinning bypassed, so `capture` can decode its HTTPS |
| `./redroid.sh frida script <name> <package> [args]` | Run a bundled crypto, conceal, native-unpin or flutter-unpin script |
| `./redroid.sh frida exec <tool> [args]` | Run any Frida CLI tool (`frida`, `frida-ps`, `frida-trace`, ...) against the guest |

Lifecycle operations use a lock and a private state file. Repeated `stop` calls
are safe, and interrupted startup is recovered on the next lifecycle command.

## Configuration

Defaults are in `redroid.env`:

- pinned base and local image names
- container name and loopback ADB port
- Bluetooth adapter, expected USB ID, and `BT_ENABLE` (default `1`)
- capture directory (`CAPTURE_DIR`) and preferred mitmproxy port (`MITM_PORT`)
- transparent capture table (`CAPTURE_NFT_TABLE`) and proxy-only group (`MITM_GID`)
- host-forwarded Frida port (`FRIDA_PORT`, loopback only)
- persistent data directory
- snapshot directory (`SNAPSHOT_DIR`, default `./snapshots`)
- APK extraction directory (`PULL_DIR`, default `./apps`)
- display resolution, density, and frame rate
- GPU and native-bridge settings
- startup timeout and host network-namespace path

For machine-specific settings, copy the file to `redroid.local.env` (ignored by
Git) and select it explicitly:

```sh
cp redroid.env redroid.local.env
REDROID_CONFIG=./redroid.local.env ./redroid.sh setup
REDROID_CONFIG=./redroid.local.env ./redroid.sh start
```

Use the same configuration for every lifecycle command.

Optional identity overrides are empty by default. Set them in your local config:

```sh
REDROID_MODEL='Lab Phone'
REDROID_MANUFACTURER='Lab'
REDROID_BRAND=lab
REDROID_DEVICE=lab_device
REDROID_PRODUCT=lab_product
REDROID_FINGERPRINT='lab/lab_product/lab_device:14/LAB/1:user/release-keys'
REDROID_QEMU=0
```

They map to `ro.product.model`, `.manufacturer`, `.brand`, `.device`, `.name`,
`ro.build.fingerprint` and `ro.kernel.qemu`. Empty values preserve the image
properties; old local configs inherit empty defaults. Values are passed as
individual startup arguments, including spaces. Apply changes by stopping and
starting the container with the same config; an already-running container and
snapshot restarts retain their original arguments. These are cosmetic property
overrides supported by [redroid](https://github.com/remote-android/redroid-doc#configuration),
not hardware/ABI changes or integrity attestation. Apps may inspect additional
properties or kernel/device signals. Inconsistent profiles may change app behavior.

Android data persists under `data/`. Install applications with
`./redroid.sh install /path/to/application.apk` (or a directory of split APKs).
No Google services or Play Store are included.

## App pull and static analysis

```sh
./redroid.sh pull com.example.app
./redroid.sh pull com.example.app --apktool --jadx
```

`pull` queries Android with `pm path` and copies every installed APK for that
package into a new private `apps/<package>/<UTC timestamp>-<random suffix>/`
directory. Original filenames are preserved, including split APKs; the complete
directory can be passed back to `./redroid.sh install <directory>`. Each run
creates a separate directory, leaving earlier pulls intact. Only installed APKs
are copied, not app databases, preferences or missing on-demand modules.

The optional host tools must already be on `PATH`. With `--apktool`,
[Apktool](https://apktool.org/docs/cli-parameters/) decodes each APK into
`apktool/<APK filename without .apk>/`. With `--jadx`,
[JADX](https://github.com/skylot/jadx#usage) receives the APK and all splits
together and writes to `jadx/`. Both flags can be combined. The lifecycle lock
is held during extraction and released before analysis.

Missing tools fail before extraction. Copy failures return a nonzero status and
leave incomplete files named `*.apk.part`; do not reinstall an incomplete pull.
Analysis failures also return a nonzero status, keeping the extracted APKs and
any analysis output for inspection. When both tools are requested, each is
attempted even if the other reports errors.

`PULL_DIR` selects the output root; relative paths are resolved from the
repository. Existing local configurations inherit the shipped default. `apps/`
is excluded from Git and the Docker build context, including decoded sources
and resources; exclude custom output locations yourself.

`pull <package> --report` reuses Apktool decoding (no separate Android SDK tool)
and requires host Python 3.9+. It writes `report.json` next to the APKs, covering
exported activities/aliases, services, receivers and providers, their permissions
and enabled flags, VIEW deep links, requested/defined permissions, debuggable,
backup and cleartext flags, plus decoded network-security XML variants.
The report accounts for legacy exported defaults and includes split manifests.
Raw intent-filter data elements are kept together rather than inventing URL
combinations. Resource-valued flags remain strings and unresolved security
resources are marked `resolved: false`. This is a static inventory: exported
components may still require permissions or be disabled, and runtime receivers,
code checks and platform backup rules need separate investigation.
`--report` combines with `--apktool`/`--jadx`; decode/report errors return nonzero
and retain APKs and intermediate output. No report is published after a decode
failure.

## App data pulls and diffs

```sh
./redroid.sh appdata pull com.example.app
# ... perform an action in the app ...
./redroid.sh appdata pull com.example.app
./redroid.sh appdata diff com.example.app
```

`pull` streams `/data/data/<package>` (Android user 0) as a root-created tar from
the guest and extracts it as your host user into a private
`appdata/<package>/<UTC timestamp>-<random suffix>/data/` directory. Preferences,
SQLite files (including WAL/SHM), and other private files are copied. Existing
pulls are preserved. The extractor rejects paths and links escaping the output,
special files and writes through symlinks. Failed copies keep `data.part/` and
are excluded from diffs. Files are host-owned with private permissions; this
is an investigation copy, not a restorable filesystem backup.

`diff` compares the last two completed pulls by completion time, without ADB.
It lists added/removed/changed paths and unified UTF-8 text diffs; binary files
(including SQLite) and files over 1 MiB are compared by SHA-256, not database
rows. Differences return success; missing copies and read errors fail.
Pulls hold the lifecycle lock but do not stop the app: concurrent writes can
produce inconsistent databases. Quiesce the app yourself for consistent data;
use full snapshots for restoration. External storage and other Android users
are excluded. `APPDATA_DIR` overrides the root directory; old local configs
inherit the default. The default directory is excluded from Git and Docker;
exclude custom locations yourself. Copies may contain credentials and tokens.
Requires host Python 3.9+ and guest root, already provided by redroid.

## Snapshots

```sh
./redroid.sh snapshot save clean-app
# ... install apps, sign in, change settings ...
./redroid.sh snapshot restore clean-app
```

Snapshots copy the entire `REDROID_DATA_DIR` into `snapshots/<name>/data/`.
Names start with a letter or digit and contain up to 64 letters, digits, dots,
underscores or hyphens. Existing names are never overwritten. Use the same
configuration and image when saving and restoring; snapshots contain only
Android data, not the container image or its writable layer.

Both commands hold the lifecycle lock, end any active packet capture and stop
the existing container before copying. The container is restarted and Android
boot is checked only if it was running beforehand. Its Bluetooth mode and host
ownership state stay in place; capture and Frida sessions must be started again.
Snapshots also work when Android is already stopped or the container is absent.

Restore **replaces all current Android data**, including installed apps,
credentials, settings and Bluetooth bonds. It stages the copy next to the data
directory before swapping it into place; a failed copy leaves current data
intact. Ownership, permissions, links and extended attributes are preserved via
`sudo cp -a`, with copy-on-write copies where the filesystem supports them.
Otherwise allow space for a full copy. Snapshot and data directories must not
contain one another.

If restarting after a completed restore fails, the command retains the previous
data under `.redroid-restore.*/previous` next to `REDROID_DATA_DIR`. Run
`./redroid.sh stop` to recover host ownership before investigating. A forced
termination or power loss can also leave staging directories there or under
`snapshots/.save-*`; inspect them before manual recovery or removal.

Snapshots contain the same private app data and credentials as `data/`. The
default `snapshots/` directory and restore staging directories are excluded from
Git and the Docker build context; exclude custom locations yourself. Snapshot
directories are created private to the calling user.

Existing local configurations inherit the shipped snapshot directory default
unless they set `SNAPSHOT_DIR` themselves.

## Packet capture

```sh
./redroid.sh start --no-bt
./redroid.sh install ./some-app-splits/
./redroid.sh capture start       # --no-mitm for raw packets only
./redroid.sh launch com.example.app
# ... drive the app with ./redroid.sh screen ...
./redroid.sh capture stop
```

Each session is written to `captures/<UTC timestamp>-<random suffix>/` (ignored by Git):

| File | Content |
| --- | --- |
| `full.pcap` | Every packet in the container's network namespace (HTTPS, UDP/P2P, STUN/TURN, MQTT, DNS), captured by `tcpdump` entered with `nsenter` |
| `flows.mitm` | Decoded HTTP(S) flows; read with `mitmweb --rfile` |
| `sslkeylog.txt` | TLS session keys from mitmproxy |
| `full-decrypted.pcapng` | `full.pcap` with the keys injected, so Wireshark decrypts the proxied HTTPS |

By default, mitmproxy listens on the Docker gateway and Android's global
`http_proxy` points at it. The mitmproxy CA is copied into the guest's system
and conscrypt trust stores each time a capture starts.

To also intercept apps that ignore the system proxy:

```sh
./redroid.sh capture start --transparent
# ... restart the app to open fresh connections ...
./redroid.sh capture stop
```

This mode runs mitmproxy inside the container's network namespace as the calling
user, with capabilities dropped and a dedicated socket group (`MITM_GID`,
`2147483647` by default). A session-owned nftables table (`CAPTURE_NFT_TABLE`,
`redroid_capture` by default) redirects new IPv4/IPv6 TCP connections on ports
80 and 443 to the proxy's loopback listeners. Proxy traffic and loopback
destinations are excluded to avoid loops. No system proxy configuration is
required; it is temporarily disabled, and its previous value is restored on
stop, as it is in explicit proxy mode. The reserved group must remain unused
by Android.

Run this command as your normal host user; it requests sudo only for namespace,
firewall and module operations.

Rules stay in Android's namespace; host nftables rules, routes and forwarding
settings are unchanged. The host's `nft_redir` module is loaded if necessary
and unloaded on stop only if this capture introduced it. The proxy uses host
files but does not enter the host network namespace. This mode requires
util-linux's `setpriv` and `lsns`, kmod's `modprobe`/`rmmod`, kernel nftables
NAT/redirect support, and a mitmproxy version supporting multiple `--mode`
listeners.

Namespace identity and table name/ownership are saved with the session. Stop
removes the table before terminating the proxy; `stop`, snapshots and failed
capture startup all use the same cleanup path. If cleanup fails, capture state
is retained: correct the error and retry `capture stop`. Preexisting tables are
never overwritten or deleted.

If Android has already stopped, cleanup still releases the capture processes
and firewall state. Its saved proxy cannot be restored through ADB while it is
offline; the previous value is kept in `proxy.before` for manual recovery.

Transparent capture does not bypass certificate pinning or app-specific CA
stores; use Frida where needed. QUIC/HTTP3 (UDP/443) is blocked in Android’s
namespace in both proxy modes to encourage TCP fallback; apps without fallback
may fail. Stop removes the session-owned table. Nonstandard ports and non-HTTP
protocols remain raw in the pcap. Existing connections must be
reopened. `--no-mitm` and `--transparent` cannot be combined; raw mode changes
neither the proxy nor firewall.


To proxy a single installed app (Android user 0):

```sh
./redroid.sh capture start --transparent --app com.example.app
```

The exact package UID is recorded in `app.package`/`app.uid`. TCP redirection
and QUIC blocking match only that UID; `flows.mitm` excludes other UIDs.
The pcap still records all traffic. Packages sharing a UID are inseparable;
isolated processes and traffic delegated to other UIDs are outside this filter.
`--app` requires `--transparent`.


Optional timeline artifacts share the capture directory:

```sh
./redroid.sh capture start --transparent --app com.example.app --logcat --record --btsnoop
```

Choose any flags: `--logcat` requires `--app` and writes UID-filtered, epoch-timed
logcat to `logcat.log`; `--record` runs a headless, silent scrcpy recording into
`screen.mkv`; `--btsnoop` copies the existing Bluetooth HCI log on stop into
`btsnoop_hci.log` (with a warning if unavailable). HCI logging must already be
enabled; this copies its current ring file, which may include earlier events
or lose events on rotation. No Bluetooth setting is changed by capture.
`timeline.tsv` records host epoch timestamps, a bracketed guest clock sample,
and recorder start/stop markers. Pcap, flows, logcat and HCI retain their own
timestamps; video starts at a relative offset, so alignment is approximate,
within recorder startup delay, rather than frame-accurate. Inspect clock
samples for host/guest skew. Stop and rollback terminate timeline workers;
SIGINT lets scrcpy finalize the recording. Requires an installed scrcpy with
`--no-playback` or older `--no-display` support. A separate `screen` can supply
interactive controls. All artifacts may contain private app data.

`tcpdump` runs as root through `sudo` and then drops privileges to the invoking
user, so artifacts are user-owned. Captures contain decrypted credentials and
personal data: keep `captures/` private.

## Root-based app investigation (Frida)

```sh
./redroid.sh start --no-bt
./redroid.sh install ./some-app.apk
./redroid.sh frida start
./redroid.sh capture start
./redroid.sh frida unpin com.example.app   # blocks; stays attached while you drive the app
# ... in another terminal: ./redroid.sh screen ...
# Ctrl-C the unpin command once done, then:
./redroid.sh capture stop
./redroid.sh frida stop
```

`frida start` downloads the pinned `frida-server` release (checked against
`build-inputs.env`), pushes it to `/data/local/tmp`, and runs it as root in the
guest; the server port is forwarded to the host loopback only. `frida unpin`
spawns an app with [frida/unpin.js](frida/unpin.js) loaded, which patches the
platform `TrustManager`, `SSLContext`, network-security-config pin checks, and
OkHttp's `CertificatePinner` so the mitmproxy CA (installed by `capture start`)
is accepted — this closes the "apps that pin certificates" gap from the
packet-capture section above, for apps that pin in Java. The hooks apply only
while the command stays attached; `frida exec` runs any other Frida CLI tool
(e.g. `frida-trace`) the same way.

Bundled scripts stay active while attached:

```sh
./redroid.sh frida script crypto com.example.app
./redroid.sh frida script conceal com.example.app
./redroid.sh frida script native-unpin com.example.app
./redroid.sh capture start --transparent --app com.example.app
./redroid.sh frida script flutter-unpin com.example.app
```

- `crypto`: timestamped Java Cipher/Mac/MessageDigest input, output, keys and
  Cipher IVs as hex, with algorithm, object/thread IDs and buffer metadata.
  Dumps stop at 4096 bytes; offsets/lengths remain in the arguments.
  Non-exportable keys and native crypto are outside these hooks. Terminal output
  contains secret material.
- `conceal`: hides selected su/Magisk/emulator files and commands, substitutes
  common Build/system properties, and disables common RootBeer checks in the
  attached process. Actual device/host identity stays unchanged. Custom checks,
  proc/mount inspection and remote integrity attestation remain outside coverage.
- `native-unpin`: hooks exported OpenSSL/BoringSSL verification setters/results,
  including late-loaded libraries, with their respective success conventions.
  Reopen connections; static/stripped implementations and custom native pin
  comparisons need targeted hooks.
- `flutter-unpin`: replaces a unique BoringSSL chain/peer verifier symbol in
  `libflutter.so`. It prints `NOT hooked` without a compatible symbol. Most release
  engines are stripped: find the verifier offset and first 8–64 bytes in that
  exact build, then pass Frida `-P` JSON parameters: `flutterOffset` (hex string),
  `flutterBytes` (hex without spaces), `flutterVerifier` (`chain` for the bool
  `ssl_crypto_x509_session_verify_cert_chain`, success 1; `peer` for the enum
  `ssl_verify_peer_cert`, success 0). The script checks bounds, executable memory,
  ARM64 alignment and exact bytes before hooking. This detects mismatched builds,
  without proving the offset identifies the correct function. No guessed offsets
  or signature scans are used. Require a `hooked` message and decoded requests.
  Hooks into translated ARM code are unverified; prefer native x86_64 on this host.

Extra arguments pass through to Frida, including `-P` and additional `-l` files
(e.g. `-l "$PWD/frida/unpin.js"` to combine Java pinning bypass with a pack script).
Flutter/native clients that ignore Android's system proxy need transparent capture.
Hooks follow the [Frida module API](https://frida.re/docs/javascript-api/#process)
and [BoringSSL verification conventions](https://github.com/google/boringssl/blob/master/include/openssl/ssl.h).

## ARM application support

The pinned image contains `libndk_translation` and ARM64 guest libraries. The
setup advertises and verifies `arm64-v8a`; ARM64-only JNI code has been tested
successfully.

The image does not contain the 32-bit translator required for ARMv7-only APKs.
It therefore does not advertise `armeabi-v7a`, avoiding installations that
would fail later at runtime. Prefer APKs that provide `arm64-v8a` or x86/x86_64.

When a local Android SDK, NDK, and build-tools installation is detected, setup
builds a small ARM64-only smoke APK from the checked-in sources and `start`
installs, launches, verifies, and removes it automatically. The Android SDK is
not otherwise required.

## Bluetooth behavior and safety

`start` runtime-masks and stops both BlueZ systemd unit names before powering
down `hci0`. Android then opens the controller through `HCI_CHANNEL_USER`.
While redroid is running:

- Linux Bluetooth keyboards, mice, audio devices, and other connections are
  unavailable.
- D-Bus cannot reactivate BlueZ and steal the controller.
- the Android and Linux Bluetooth key stores remain separate.

Avoid bonding the same peripheral independently in Android and BlueZ. Both
stacks use the controller's public address but retain different link keys, which
can invalidate an existing pairing.

`stop` releases the HCI channel, restores adapter power before restarting BlueZ,
and verifies the final state. A guarded `btusb` reset is available as a fallback
for controllers that do not recover cleanly.

## Security model

The container is privileged and, when Bluetooth is enabled, the Bluetooth HAL
receives access to the host network namespace (without it, the HAL has no
namespace to enter and exits).
During a capture, the mitmproxy CA is trusted by the Android guest only. Treat the image and installed Android applications as
trusted code.

ADB is published only on `127.0.0.1`; `ADB_HOST` is rejected if changed to a
non-loopback address. While redroid runs, an nftables table (`NFT_TABLE`,
`redroid_guard` by default) also drops packets for the ADB port that are
addressed to this host but arrive on a non-loopback interface. It filters in
`prerouting` before Docker's DNAT, so LAN neighbours cannot reach the loopback
publish by routing to `127.0.0.1` through the host. `start` refuses to run if a
table with that name already exists, and `stop` only deletes the table it
created. The script snapshots physical addresses, main routes,
policy rules, and nftables state before startup and validates them during boot
and restoration.

Do not expose port 5555 through another proxy, firewall rule, or SSH forwarding
without understanding that ADB provides extensive control over the Android
instance.

## Troubleshooting

Start with:

```sh
./redroid.sh status
./redroid.sh logs
```

Common checks:

```sh
docker info
grep binder /proc/filesystems
ls -l /dev/dri/renderD128
readlink -f /sys/class/bluetooth/hci0/device
ss -ltn 'sport = :5555'
```

If startup fails, do not start BlueZ manually while rollback is active. Let the
script finish, then run `./redroid.sh stop` if recovery needs to be repeated.
Bluetooth diagnostics include `dumpsys bluetooth_manager`, filtered logcat, and
an HCI snoop file under `.runtime/` when Android produces one.

On modern scrcpy releases, `screen` selects Android's available AAC encoder;
the default Opus encoder is absent from this redroid image. Ubuntu 22.04 and
24.04 currently package older scrcpy versions without audio forwarding. The
script detects that capability and starts video/input mirroring without audio
instead of passing unsupported options.

## Reproducibility and repository hygiene

The build pins the redroid image digest, Debian builder digest, AOSP btlinux
source, VNDK snapshot, and Android NDK checksum. It validates source trees, ELF
dependencies, and strong undefined symbols against the exact base image. A full
AOSP checkout is not required.

Git excludes persistent Android data, runtime ownership state, logs, generated
APKs, signing material, caches, and local configuration overrides (including `*.local.md` agent notes). Docker's
build context excludes the same host-only content. Review `git status --ignored`
before the first commit to confirm that no application data or pairing material
will be shared.
