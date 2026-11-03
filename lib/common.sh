# shellcheck shell=bash
# Shared helpers: messages, configuration, Docker/ADB wrappers and the lifecycle lock.

die() {
    echo "error: $*" >&2
    exit 1
}

note() {
    echo "==> $*"
}

warn() {
    echo "warning: $*" >&2
}

# type -P: look in PATH only, so wrapper functions such as adb() do not count.
need() {
    local cmd
    for cmd; do
        type -P "$cmd" >/dev/null || die "missing command '$cmd'"
    done
}

valid_port() {
    [[ $1 =~ ^[1-9][0-9]{0,4}$ ]] && (( $1 <= 65535 ))
}

validate_package() {
    [[ $1 =~ ^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)*$ ]] || \
        die "invalid Android package name: $1"
}

# Resolve the exact installed package for Android user 0, not a substring match.
app_uid() {
    local package=$1 uid
    validate_package "$package"
    uid=$(adb_shell pm list packages -U --user 0 "$package" | tr -d '\r' | \
        awk -v package="package:$package" '$1 == package && $2 ~ /^uid:/ {sub(/^uid:/, "", $2); print $2}') || \
        die "could not query UID for $package"
    if [[ ! $uid =~ ^(0|[1-9][0-9]{0,9})$ ]] || (( uid >= 4294967295 )); then
        die "package is missing or has an invalid UID: $package"
    fi
    printf '%s\n' "$uid"
}

load_config() {
    [[ -r $CONFIG_FILE ]] || die "configuration not found: $CONFIG_FILE"
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
    local name default
    local identity_names=(REDROID_MODEL REDROID_MANUFACTURER REDROID_BRAND
        REDROID_DEVICE REDROID_PRODUCT REDROID_FINGERPRINT REDROID_QEMU)
    # Existing local configurations inherit defaults for newly added settings.
    for name in SNAPSHOT_DIR PULL_DIR APPDATA_DIR CAPTURE_NFT_TABLE MITM_GID CAMERA_ENABLE "${identity_names[@]}"; do
        if [[ ! -v $name ]]; then
            # shellcheck source=/dev/null
            default=$(source "$SCRIPT_DIR/redroid.env"; printf '%s' "${!name}")
            printf -v "$name" '%s' "$default"
        fi
    done
    for name in BASE_IMAGE LOCAL_IMAGE CONTAINER_NAME ADB_HOST ADB_PORT \
        BT_ADAPTER NFT_TABLE REDROID_DATA_DIR REDROID_WIDTH REDROID_HEIGHT \
        REDROID_DPI REDROID_FPS REDROID_GPU_MODE REDROID_NATIVE_BRIDGE \
        HOST_NETNS_SOURCE BOOT_TIMEOUT BT_ENABLE CAPTURE_DIR MITM_PORT FRIDA_PORT \
        SNAPSHOT_DIR PULL_DIR APPDATA_DIR CAPTURE_NFT_TABLE MITM_GID CAMERA_ENABLE; do
        [[ -n ${!name:-} ]] || die "missing configuration value '$name'"
    done
    for name in ADB_PORT MITM_PORT FRIDA_PORT; do
        valid_port "${!name}" || die "$name must be between 1 and 65535"
    done
    [[ $ADB_HOST == 127.0.0.1 ]] || die "ADB_HOST must be 127.0.0.1"
    [[ $BT_ENABLE == [01] ]] || die "BT_ENABLE must be 0 or 1"
    [[ $CAMERA_ENABLE == [01] ]] || die "CAMERA_ENABLE must be 0 or 1"
    [[ $HOST_NETNS_SOURCE == /* ]] || die "HOST_NETNS_SOURCE must be an absolute path"
    for name in NFT_TABLE CAPTURE_NFT_TABLE; do
        [[ ${!name} =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die "$name contains invalid characters"
    done
    if [[ ! $MITM_GID =~ ^[1-9][0-9]{9}$ ]] || (( MITM_GID < 1000000000 || MITM_GID > 2147483647 )); then
        die "MITM_GID must be an unused Android group between 1000000000 and 2147483647"
    fi
    # Identity keys are optional, but must remain single property values.
    for name in "${identity_names[@]}"; do
        [[ ${!name} != *$'\n'* && ${!name} != *$'\r'* ]] || die "$name must be a single line"
    done
    [[ -z $REDROID_QEMU || $REDROID_QEMU == [01] ]] || die "REDROID_QEMU must be empty, 0 or 1"
    # Relative directories are relative to the toolbox, not the caller's cwd.
    for name in REDROID_DATA_DIR CAPTURE_DIR SNAPSHOT_DIR PULL_DIR APPDATA_DIR; do
        [[ ${!name} == /* ]] || printf -v "$name" '%s' "$SCRIPT_DIR/${!name#./}"
    done
    ADB_SERIAL=$ADB_HOST:$ADB_PORT
}

acquire_lock() {
    mkdir -p "$STATE_DIR"
    exec 9>"$LOCK_FILE"
    flock -n 9 || die "another redroid lifecycle command is running"
}

# Run HANDLER on exit; signals exit non-zero so the handler sees a failure.
trap_exit() {
    # shellcheck disable=SC2064 # $1 is a handler name; expanding it now is the point
    trap "$1" EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
}

# Fresh private directory under PARENT named by UTC time (call after umask 077).
stamped_dir() {
    mkdir -p -- "$1"
    mktemp -d "$1/$(date -u +%Y%m%d-%H%M%SZ)-XXXXXX"
}

container_exists() {
    docker container inspect "$CONTAINER_NAME" >/dev/null 2>&1
}

container_running() {
    [[ $(docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null || true) == true ]]
}

require_running() {
    container_running || die "container '$CONTAINER_NAME' is not running; run './redroid.sh start'"
}

# A first `adb` call forks the adb server, which would otherwise inherit the
# lifecycle lock (fd 9) and hold it after this script exits.
adb() {
    command adb "$@" 9>&-
}

adb_dev() {
    adb -s "$ADB_SERIAL" "$@"
}

adb_shell() {
    adb_dev shell "$@"
}

# `timeout` runs the adb binary itself, bypassing the wrapper, so close fd 9 here too.
adb_timeout() {
    timeout 10 adb -s "$ADB_SERIAL" "$@" 9>&-
}

adb_connect() {
    adb connect "$ADB_SERIAL" >/dev/null 2>&1 || true
}

android_booted() {
    [[ $(adb_shell getprop sys.boot_completed 2>/dev/null | tr -d '\r') == 1 ]]
}
