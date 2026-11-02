# Redroid-Lab

A toolbox for running and investigating a pinned Android 14 [redroid](https://github.com/remote-android/redroid-doc) container on an x86_64 Linux host: persistent data, Intel GPU acceleration, loopback-only ADB and scrcpy, ARM64 application translation, and working access to a real physical Bluetooth controller.

The project started as a Bluetooth-passthrough image and is growing into a
general lab for poking at Android apps: packet capture, root-level app
inspection, and similar reverse-engineering workflows.

## Scope

| Capability | Status |
| --- | --- |
| Pinned redroid 14 image with persistent data, Intel GPU, scrcpy | Available |
| ARM64 application translation (`libndk_translation`) | Available |
| Physical Bluetooth passthrough (AOSP Linux-HCI HAL) | Available |
| Network packet capture from the container | Planned |
| Root-based app investigation tooling | Planned |

"Planned" rows are goals; none is implemented yet.

Contributors and AI coding agents: see [AGENTS.md](AGENTS.md).

## Physical Bluetooth

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
```

Android stays in Docker's network namespace, preventing `netd` from modifying
the host's physical interfaces or policy routes. Only the btlinux HAL enters
the host network namespace, which is necessary to open Linux Bluetooth HCI
sockets. The controller is exclusive: BlueZ and Android cannot own it at the
same time.

## Host requirements

- x86_64 Linux with systemd and Docker
- Binder IPC and BinderFS in the running kernel
- Intel DRM render node at `/dev/dri/renderD128`
- a Bluetooth controller exposed as `hci0` and driven by `btusb`
- approximately 10 GB of free space for images, build inputs, and cache
- outbound HTTPS access during the initial build

The checked-in defaults identify the reference Intel AX211 by USB ID
`8087:0033`. On another machine, verify the intended adapter and update or clear
`BT_EXPECTED_USB_ID` in `redroid.env`. Clearing it disables the hardware identity
guard; it does not make unsupported adapters safe automatically.

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

Stop Android and return the Bluetooth adapter to Linux with:

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
| `./redroid.sh start` | Reserve `hci0`, boot Android, and validate networking, Bluetooth, and ARM64 translation |
| `./redroid.sh stop` | Remove Android and restore the previous BlueZ and adapter state |
| `./redroid.sh screen` | Open scrcpy; use AAC on modern releases and video/input-only mode on older Ubuntu packages |
| `./redroid.sh status` | Show container, Android, ABI, BlueZ, and btlinux readiness |
| `./redroid.sh logs` | Print Bluetooth diagnostics and save HCI snoop data when available |

Lifecycle operations use a lock and a private state file. Repeated `stop` calls
are safe, and interrupted startup is recovered on the next lifecycle command.

## Configuration

Defaults are in `redroid.env`:

- pinned base and local image names
- container name and loopback ADB port
- Bluetooth adapter and expected USB ID
- persistent data directory
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

Android data persists under `data/`. Install applications directly with:

```sh
adb -s 127.0.0.1:5555 install -r /path/to/application.apk
```

No Google services or Play Store are included.

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

The container is privileged and the Bluetooth HAL receives access to the host
network namespace. Treat the image and installed Android applications as
trusted code.

ADB is published only on `127.0.0.1`; `ADB_HOST` is rejected if changed to a
non-loopback address. The script snapshots physical addresses, main routes,
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
