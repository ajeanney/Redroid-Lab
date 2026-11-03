#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
CONFIG_FILE=${REDROID_CONFIG:-$SCRIPT_DIR/redroid.env}
INPUTS_FILE=$SCRIPT_DIR/build-inputs.env
STATE_DIR=$SCRIPT_DIR/.runtime
STATE_FILE=$STATE_DIR/state.env
LOCK_FILE=$STATE_DIR/lock
CAPTURE_CURRENT=$STATE_DIR/capture.current
SMOKE_APK=$STATE_DIR/redroid-arm64-smoke.apk
FRIDA_DIR=$SCRIPT_DIR/.cache/frida
FRIDA_GUEST_BIN=/data/local/tmp/frida-server

# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/setup.sh
source "$SCRIPT_DIR/lib/setup.sh"
# shellcheck source=lib/bluetooth.sh
source "$SCRIPT_DIR/lib/bluetooth.sh"
# shellcheck source=lib/lifecycle.sh
source "$SCRIPT_DIR/lib/lifecycle.sh"
# shellcheck source=lib/capture.sh
source "$SCRIPT_DIR/lib/capture.sh"
# shellcheck source=lib/apps.sh
source "$SCRIPT_DIR/lib/apps.sh"
# shellcheck source=lib/snapshot.sh
source "$SCRIPT_DIR/lib/snapshot.sh"
# shellcheck source=lib/frida.sh
source "$SCRIPT_DIR/lib/frida.sh"

usage() {
    cat <<'EOF'
Usage: ./redroid.sh {setup|start|stop|screen|status|logs|install|pull|launch|snapshot|capture|frida}

  setup    Install missing Arch/Debian/Ubuntu tools and build the image
  start    Boot redroid; give hci0 to Android unless --no-bt (or BT_ENABLE=0)
  stop     Stop redroid (ending any capture) and restore the host
  screen   Open the Android display with scrcpy
  status   Show container, host Bluetooth, Android, ABI, and capture status
  logs     Collect container and Android Bluetooth diagnostics
  install  Install an APK, several split APKs, or a directory of splits
  pull     pull <package> [--apktool] [--jadx]: extract APKs and optionally decode
  launch   Start an installed app by package name
  snapshot snapshot save|restore <name>: copy stopped Android data, then restart
  capture  capture start [--no-mitm|--transparent] [--app <pkg>] [--logcat] [--record] [--btsnoop] | stop | status: pcap + decoded HTTPS
  frida    frida start | stop | unpin <package> | exec <tool> [args]: root hooking
EOF
}

load_config
case ${1:-} in
    setup) cmd_setup ;;
    start) shift; cmd_start "$@" ;;
    stop) cmd_stop ;;
    screen) cmd_screen ;;
    status) cmd_status ;;
    logs) cmd_logs ;;
    install) shift; cmd_install "$@" ;;
    pull) shift; cmd_pull "$@" ;;
    launch) shift; cmd_launch "$@" ;;
    snapshot) shift; cmd_snapshot "$@" ;;
    capture) shift; cmd_capture "$@" ;;
    frida) shift; cmd_frida "$@" ;;
    *) usage; exit 2 ;;
esac
