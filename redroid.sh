#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
CONFIG_FILE=${REDROID_CONFIG:-$SCRIPT_DIR/redroid.env}
INPUTS_FILE=$SCRIPT_DIR/build-inputs.env
STATE_DIR=$SCRIPT_DIR/.runtime
STATE_FILE=$STATE_DIR/state.env
LOCK_FILE=$STATE_DIR/lock

die() {
    echo "error: $*" >&2
    exit 1
}

note() {
    echo "==> $*"
}

need() {
    command -v "$1" >/dev/null 2>&1 || die "missing command '$1'"
}

load_config() {
    [[ -r $CONFIG_FILE ]] || die "configuration not found: $CONFIG_FILE"
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"

    local name
    for name in BASE_IMAGE LOCAL_IMAGE CONTAINER_NAME ADB_HOST ADB_PORT \
        BT_ADAPTER NFT_TABLE REDROID_DATA_DIR REDROID_WIDTH REDROID_HEIGHT \
        REDROID_DPI REDROID_FPS REDROID_GPU_MODE REDROID_NATIVE_BRIDGE \
        HOST_NETNS_SOURCE BOOT_TIMEOUT BT_ENABLE CAPTURE_DIR MITM_PORT; do
        [[ -n ${!name:-} ]] || die "missing configuration value '$name'"
    done
    if [[ ! $ADB_PORT =~ ^[0-9]+$ ]] || (( ADB_PORT < 1 || ADB_PORT > 65535 )); then
        die "ADB_PORT must be between 1 and 65535"
    fi
    [[ $ADB_HOST == 127.0.0.1 ]] || die "ADB_HOST must be 127.0.0.1"
    [[ $BT_ENABLE == [01] ]] || die "BT_ENABLE must be 0 or 1"
    if [[ ! $MITM_PORT =~ ^[0-9]+$ ]] || (( MITM_PORT < 1 || MITM_PORT > 65535 )); then
        die "MITM_PORT must be between 1 and 65535"
    fi
    [[ $HOST_NETNS_SOURCE == /* ]] || die "HOST_NETNS_SOURCE must be an absolute path"
    [[ $NFT_TABLE =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || \
        die "NFT_TABLE contains invalid characters"

    local configured_data=$REDROID_DATA_DIR
    if [[ $configured_data != /* ]]; then
        REDROID_DATA_DIR=$SCRIPT_DIR/$configured_data
    fi
    [[ $CAPTURE_DIR == /* ]] || CAPTURE_DIR=$SCRIPT_DIR/${CAPTURE_DIR#./}
    ADB_SERIAL=$ADB_HOST:$ADB_PORT
}

container_exists() {
    docker container inspect "$CONTAINER_NAME" >/dev/null 2>&1
}

container_running() {
    [[ $(docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null || true) == true ]]
}

# A first `adb` call forks the adb server, which would otherwise inherit the
# lifecycle lock (fd 9) and hold it after this script exits.
adb() {
    command adb "$@" 9>&-
}

adb_shell() {
    adb -s "$ADB_SERIAL" shell "$@"
}

acquire_lock() {
    mkdir -p "$STATE_DIR"
    exec 9>"$LOCK_FILE"
    flock -n 9 || die "another redroid lifecycle command is running"
}

require_runtime_tools() {
    local tool
    for tool in docker adb nft flock sudo ip ss sha256sum modprobe; do
        need "$tool"
    done
}

require_bt_tools() {
    local tool
    for tool in systemctl btmgmt rfkill; do
        need "$tool"
    done
}

# True when the lifecycle state on disk says this run took over Bluetooth.
# States written before BT_MANAGED existed always did.
bt_managed_in_state() {
    [[ -r $STATE_FILE ]] && ! grep -q '^BT_MANAGED=0$' "$STATE_FILE"
}

host_family() {
    local id='' id_like=''
    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        source /etc/os-release
        id=${ID:-}
        id_like=${ID_LIKE:-}
    fi
    case $id in
        arch|manjaro|endeavouros) echo arch; return ;;
        ubuntu) echo ubuntu; return ;;
        debian) echo debian; return ;;
    esac
    case " $id_like " in
        *' arch '*) echo arch ;;
        *' ubuntu '*) echo ubuntu ;;
        *' debian '*) echo debian ;;
        *) echo unsupported ;;
    esac
}

binder_guidance() {
    case $(host_family) in
        arch) echo "use an Arch kernel with CONFIG_ANDROID_BINDERFS and CONFIG_ANDROID_BINDER_IPC enabled" ;;
        ubuntu) echo "install linux-modules-extra-$(uname -r), then load binder_linux; otherwise use an Ubuntu kernel with CONFIG_ANDROID_BINDERFS and CONFIG_ANDROID_BINDER_IPC" ;;
        debian) echo "use a kernel with CONFIG_ANDROID_BINDERFS and CONFIG_ANDROID_BINDER_IPC, or install a compatible binder_linux DKMS module" ;;
        *) echo "use a kernel with BinderFS and Android Binder IPC support" ;;
    esac
}

ensure_binder() {
    grep -Eq 'nodev[[:space:]]+binder' /proc/filesystems && return 0
    if modinfo binder_linux >/dev/null 2>&1; then
        note "Loading the host binder_linux module"
        sudo modprobe binder_linux devices=binder,hwbinder,vndbinder || true
    fi
    grep -Eq 'nodev[[:space:]]+binder' /proc/filesystems || \
        die "Binder filesystem is unavailable; $(binder_guidance)"
}

validate_adapter_identity() {
    local interface_path usb_path usb_id
    [[ -d /sys/class/bluetooth/$BT_ADAPTER ]] || \
        die "Bluetooth adapter '$BT_ADAPTER' is unavailable"
    [[ $BT_ADAPTER == hci0 ]] || \
        die "the pinned AOSP btlinux HAL supports only hci0"
    if [[ -n ${BT_EXPECTED_USB_ID:-} ]]; then
        interface_path=$(readlink -f "/sys/class/bluetooth/$BT_ADAPTER/device")
        usb_path=$interface_path
        while [[ $usb_path != / && \
                 ! ( -r $usb_path/idVendor && -r $usb_path/idProduct ) ]]; do
            usb_path=${usb_path%/*}
            [[ -n $usb_path ]] || usb_path=/
        done
        [[ -r $usb_path/idVendor && -r $usb_path/idProduct ]] || \
            die "cannot identify the USB controller behind '$BT_ADAPTER'; clear BT_EXPECTED_USB_ID to allow an unverified adapter"
        usb_id=$(<"$usb_path/idVendor"):$(<"$usb_path/idProduct")
        [[ $usb_id == "$BT_EXPECTED_USB_ID" ]] || \
            die "'$BT_ADAPTER' is USB $usb_id, expected $BT_EXPECTED_USB_ID (Intel AX211)"
    fi
}

preflight() {
    require_runtime_tools
    docker info >/dev/null 2>&1 || die "Docker daemon is unavailable"
    docker image inspect "$LOCAL_IMAGE" >/dev/null 2>&1 || \
        die "image '$LOCAL_IMAGE' is missing; run './redroid.sh setup'"
    ensure_binder
    [[ $BT_ENABLE == 0 ]] || validate_adapter_identity
    [[ -e /dev/dri/renderD128 ]] || \
        die "Intel render node /dev/dri/renderD128 is unavailable"
    [[ $BT_ENABLE == 0 || -e $HOST_NETNS_SOURCE ]] || \
        die "host network namespace is unavailable at '$HOST_NETNS_SOURCE'"
    if ss -H -ltn "sport = :$ADB_PORT" | grep -q .; then
        die "TCP port $ADB_PORT is already in use"
    fi
}

install_host_dependencies() {
    local family missing=()
    family=$(host_family)
    case $family in
        arch)
            command -v docker >/dev/null 2>&1 || missing+=(docker)
            command -v btmgmt >/dev/null 2>&1 || missing+=(bluez-utils)
            command -v adb >/dev/null 2>&1 || missing+=(android-tools)
            command -v scrcpy >/dev/null 2>&1 || missing+=(scrcpy)
            command -v nft >/dev/null 2>&1 || missing+=(nftables)
            command -v ip >/dev/null 2>&1 || missing+=(iproute2)
            command -v flock >/dev/null 2>&1 || missing+=(util-linux)
            command -v rfkill >/dev/null 2>&1 || missing+=(util-linux)
            command -v sha256sum >/dev/null 2>&1 || missing+=(coreutils)
            command -v modprobe >/dev/null 2>&1 || missing+=(kmod)
            command -v tcpdump >/dev/null 2>&1 || missing+=(tcpdump)
            command -v mitmdump >/dev/null 2>&1 || missing+=(mitmproxy)
            command -v editcap >/dev/null 2>&1 || missing+=(wireshark-cli)
            command -v nsenter >/dev/null 2>&1 || missing+=(util-linux)
            ;;
        debian|ubuntu)
            command -v docker >/dev/null 2>&1 || missing+=(docker.io)
            command -v systemctl >/dev/null 2>&1 || missing+=(systemd)
            command -v btmgmt >/dev/null 2>&1 || missing+=(bluez)
            command -v adb >/dev/null 2>&1 || missing+=(adb)
            command -v scrcpy >/dev/null 2>&1 || missing+=(scrcpy)
            command -v nft >/dev/null 2>&1 || missing+=(nftables)
            command -v ip >/dev/null 2>&1 || missing+=(iproute2)
            command -v flock >/dev/null 2>&1 || missing+=(util-linux)
            command -v rfkill >/dev/null 2>&1 || missing+=(rfkill)
            command -v sha256sum >/dev/null 2>&1 || missing+=(coreutils)
            command -v modprobe >/dev/null 2>&1 || missing+=(kmod)
            command -v tcpdump >/dev/null 2>&1 || missing+=(tcpdump)
            command -v mitmdump >/dev/null 2>&1 || missing+=(mitmproxy)
            command -v editcap >/dev/null 2>&1 || missing+=(wireshark-common)
            command -v nsenter >/dev/null 2>&1 || missing+=(util-linux)
            ;;
        *)
            die "unsupported distribution; install Docker, ADB, scrcpy, nftables, BlueZ tools, iproute2, util-linux, rfkill, kmod, tcpdump, mitmproxy, and Wireshark's editcap manually"
            ;;
    esac
    if (( ${#missing[@]} )); then
        need sudo
        case $family in
            arch)
                need pacman
                note "Installing missing Arch packages: ${missing[*]}"
                sudo pacman -S --needed --noconfirm "${missing[@]}"
                ;;
            debian|ubuntu)
                need apt-get
                note "Installing missing Debian/Ubuntu packages: ${missing[*]}"
                sudo apt-get update
                sudo apt-get install -y "${missing[@]}"
                ;;
        esac
    fi
}

validate_host_capabilities() {
    docker info >/dev/null 2>&1 || die "Docker daemon is unavailable (enable docker.service and ensure this user can access it)"
    ensure_binder
    [[ $BT_ENABLE == 0 ]] || validate_adapter_identity
    [[ -e /dev/dri/renderD128 ]] || \
        die "render node /dev/dri/renderD128 is unavailable"
    if [[ -r /sys/class/drm/renderD128/device/vendor ]] && \
       [[ $(< /sys/class/drm/renderD128/device/vendor) != 0x8086 ]]; then
        note "warning: /dev/dri/renderD128 is not an Intel GPU; if Android fails to boot, set REDROID_GPU_MODE=guest in a local config"
    fi
}

build_image() {
    local build_args=()
    local name
    # shellcheck disable=SC1090
    source "$INPUTS_FILE"
    for name in \
        BT_SOURCE_URL BT_SOURCE_TREE_SHA256 \
        VNDK_INCLUDE_URL VNDK_INCLUDE_TREE_SHA256 \
        VNDK_SHARED_URL VNDK_SHARED_TREE_SHA256 \
        NDK_URL NDK_SHA256; do
        build_args+=(--build-arg "$name=${!name}")
    done
    note "Building compact Bluetooth HAL overlay image"
    docker build --pull \
        --build-arg "BASE_IMAGE=$BASE_IMAGE" \
        "${build_args[@]}" \
        --tag "$LOCAL_IMAGE" "$SCRIPT_DIR"
}

build_arm64_smoke_apk() {
    local sdk_root=${ANDROID_SDK_ROOT:-${ANDROID_HOME:-}}
    if [[ -z $sdk_root && -d ${HOME:-}/Android/Sdk ]]; then
        sdk_root=$HOME/Android/Sdk
    fi
    if [[ -z $sdk_root || ! -d $sdk_root/build-tools || ! -d $sdk_root/platforms || \
          ! -d $sdk_root/ndk || ! -x $SCRIPT_DIR/build/build-arm64-smoke-apk.sh ]] || \
       ! command -v javac >/dev/null 2>&1 || ! command -v zip >/dev/null 2>&1; then
        note "Android SDK not found; ARM64 app smoke will be skipped at startup"
        return 0
    fi
    note "Building ARM64 native-bridge smoke APK"
    ANDROID_SDK_ROOT=$sdk_root "$SCRIPT_DIR/build/build-arm64-smoke-apk.sh" \
        "$STATE_DIR/redroid-arm64-smoke.apk"
}

cmd_setup() {
    acquire_lock
    install_host_dependencies
    require_runtime_tools
    need scrcpy
    validate_host_capabilities
    build_arm64_smoke_apk || note "ARM64 smoke APK build failed; the smoke test will be skipped at startup"
    build_image
    note "Validating image metadata"
    docker image inspect "$LOCAL_IMAGE" --format 'image={{.Id}} size={{.Size}} bytes'
    note "Setup complete"
}

write_state() {
    local bluez_active=$1 bluez_masked=$2 bt_powered=$3 modprobe_value=$4
    local address_hash=$5 route_hash=$6 policy_hash=$7 firewall_hash=$8
    umask 077
    {
        printf 'BT_MANAGED=%q\n' "$BT_ENABLE"
        printf 'BLUEZ_WAS_ACTIVE=%q\n' "$bluez_active"
        printf 'BLUEZ_WAS_MASKED=%q\n' "$bluez_masked"
        printf 'BT_WAS_POWERED=%q\n' "$bt_powered"
        printf 'MODPROBE_VALUE=%q\n' "$modprobe_value"
        printf 'ADDRESS_HASH=%q\n' "$address_hash"
        printf 'ROUTE_HASH=%q\n' "$route_hash"
        printf 'POLICY_HASH=%q\n' "$policy_hash"
        printf 'FIREWALL_BEFORE_HASH=%q\n' "$firewall_hash"
    } >"$STATE_FILE"
}

network_hash() {
    local kind=$1
    case $kind in
        address)
            {
                ip -brief -4 address show scope global
                ip -brief -6 address show scope global
            } | awk '$1 != "docker0" && $1 !~ /^br-/ && $1 !~ /^veth/' \
                | sort | sha256sum | awk '{print $1}'
            ;;
        route)
            {
                ip -o -4 route show table main
                ip -o -6 route show table main
            } | grep -Ev '(^| )dev (docker0|br-|veth)' \
                | sed -E 's/ expires [0-9]+sec//g' \
                | sort | sha256sum | awk '{print $1}'
            ;;
        policy)
            {
                ip -4 rule show
                ip -6 rule show
            } | sort | sha256sum | awk '{print $1}'
            ;;
        firewall)
            sudo nft -j list ruleset \
                | sed -E 's/"packets": ?[0-9]+/"packets":0/g; s/"bytes": ?[0-9]+/"bytes":0/g' \
                | sha256sum | awk '{print $1}'
            ;;
    esac
}

install_adb_guard() {
    if sudo nft list table inet "$NFT_TABLE" >/dev/null 2>&1; then
        die "nftables table inet/$NFT_TABLE already exists"
    fi
    sudo nft -f - <<EOF
add table inet $NFT_TABLE
add chain inet $NFT_TABLE input { type filter hook input priority -10; policy accept; }
add rule inet $NFT_TABLE input iifname != "lo" tcp dport $ADB_PORT drop comment "redroid adb loopback only"
EOF
}

remove_adb_guard() {
    sudo nft delete table inet "$NFT_TABLE" >/dev/null 2>&1 || true
}

adapter_is_powered() {
    sudo btmgmt --index "${BT_ADAPTER#hci}" info 2>/dev/null \
        | grep -Eq 'current settings:.*powered'
}

power_adapter_on() {
    local attempt=0
    while (( attempt < 3 )); do
        ((attempt += 1))
        sudo btmgmt --index "${BT_ADAPTER#hci}" power on >/dev/null 2>&1 || true
        adapter_is_powered && return 0
        sleep 1
    done
    return 1
}

reset_bluetooth_adapter() {
    local device_path usb_interface deadline
    note "Resetting $BT_ADAPTER after Android HCI ownership"

    if [[ -e /sys/class/bluetooth/$BT_ADAPTER/reset ]]; then
        printf '1' | sudo tee "/sys/class/bluetooth/$BT_ADAPTER/reset" >/dev/null || true
        sleep 2
        power_adapter_on && return 0
    fi

    validate_adapter_identity
    device_path=$(readlink -f "/sys/class/bluetooth/$BT_ADAPTER/device")
    usb_interface=${device_path##*/}
    [[ $usb_interface =~ ^[0-9]+-[0-9.]+:[0-9]+\.[0-9]+$ ]] || \
        die "cannot safely reset unexpected Bluetooth USB interface '$usb_interface'"
    [[ -L /sys/bus/usb/drivers/btusb/$usb_interface ]] || \
        die "Bluetooth interface '$usb_interface' is not bound to btusb"

    printf '%s' "$usb_interface" \
        | sudo tee /sys/bus/usb/drivers/btusb/unbind >/dev/null
    sleep 1
    if [[ ! -L /sys/bus/usb/drivers/btusb/$usb_interface ]]; then
        printf '%s' "$usb_interface" \
            | sudo tee /sys/bus/usb/drivers/btusb/bind >/dev/null 2>&1 || true
    fi
    command -v udevadm >/dev/null 2>&1 && sudo udevadm settle || true

    deadline=$((SECONDS + 10))
    while (( SECONDS < deadline )); do
        [[ -d /sys/class/bluetooth/$BT_ADAPTER ]] && break
        sleep 1
    done
    [[ -d /sys/class/bluetooth/$BT_ADAPTER ]] || \
        die "'$BT_ADAPTER' did not return after USB reset"
    sudo rfkill unblock bluetooth || true
    power_adapter_on
}

restore_host_state() {
    local bluez_was_active=0 bluez_was_masked=0 bt_was_powered=0
    local modprobe_value='' have_state=0 address_hash='' route_hash=''
    local policy_hash='' firewall_before_hash='' bt_managed=1
    RESTORE_HOST_OK=1
    RESTORED_BT_SHOULD_BE_POWERED=0
    if [[ -r $STATE_FILE ]]; then
        # shellcheck disable=SC1090
        source "$STATE_FILE"
        # These uppercase variables are written by write_state.
        # shellcheck disable=SC2153
        bluez_was_active=$BLUEZ_WAS_ACTIVE
        bt_managed=${BT_MANAGED:-1}
        bluez_was_masked=${BLUEZ_WAS_MASKED:-0}
        bt_was_powered=${BT_WAS_POWERED:-1}
        # shellcheck disable=SC2153
        modprobe_value=$MODPROBE_VALUE
        address_hash=${ADDRESS_HASH:-}
        route_hash=${ROUTE_HASH:-}
        policy_hash=${POLICY_HASH:-}
        firewall_before_hash=${FIREWALL_BEFORE_HASH:-}
        have_state=1
    fi

    remove_adb_guard
    if [[ -n $modprobe_value && $(cat /proc/sys/kernel/modprobe) != "$modprobe_value" ]]; then
        sudo sysctl -q -w "kernel.modprobe=$modprobe_value" || true
    fi
    if [[ $have_state == 1 ]]; then
        if [[ $bt_managed == 1 ]]; then
            sudo rfkill unblock bluetooth || true
            if [[ $bt_was_powered == 1 ]]; then
                RESTORED_BT_SHOULD_BE_POWERED=1
                if ! power_adapter_on && ! reset_bluetooth_adapter; then
                    echo "warning: host Bluetooth adapter could not be powered back on" >&2
                    RESTORE_HOST_OK=0
                fi
            fi
            if [[ $bluez_was_masked == 0 ]]; then
                sudo systemctl unmask --runtime bluetooth.service dbus-org.bluez.service \
                    >/dev/null 2>&1 || true
            fi
            if [[ $bluez_was_active == 1 ]]; then
                sudo systemctl start bluetooth.service || true
            fi
        fi
        if [[ -n $address_hash && $(network_hash address) != "$address_hash" ]]; then
            echo "warning: host interface addresses differ from their pre-start state" >&2
            RESTORE_HOST_OK=0
        fi
        if [[ -n $route_hash && $(network_hash route) != "$route_hash" ]]; then
            echo "warning: host routes differ from their pre-start state" >&2
            RESTORE_HOST_OK=0
        fi
        if [[ -n $policy_hash && $(network_hash policy) != "$policy_hash" ]]; then
            echo "warning: host policy routing differs from its pre-start state" >&2
            RESTORE_HOST_OK=0
        fi
        if [[ -n $firewall_before_hash && $(network_hash firewall) != "$firewall_before_hash" ]]; then
            echo "warning: host firewall differs from its pre-start state" >&2
            RESTORE_HOST_OK=0
        fi
    fi
    rm -f "$STATE_FILE"
}

stop_container() {
    adb disconnect "$ADB_SERIAL" >/dev/null 2>&1 || true
    if container_exists; then
        docker stop --time 20 "$CONTAINER_NAME" >/dev/null 2>&1 || true
        docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
    fi
}

rollback_start() {
    local exit_code=$?
    trap - EXIT INT TERM
    (( exit_code != 0 )) || return 0
    echo "startup failed; restoring host state" >&2
    stop_container
    restore_host_state
    exit "$exit_code"
}

wait_for_android() {
    local deadline=$((SECONDS + BOOT_TIMEOUT))
    note "Waiting for ADB and Android boot completion"
    while (( SECONDS < deadline )); do
        adb connect "$ADB_SERIAL" >/dev/null 2>&1 || true
        if [[ $(adb_shell getprop sys.boot_completed 2>/dev/null | tr -d '\r') == 1 ]]; then
            return 0
        fi
        if ! container_running; then
            docker logs "$CONTAINER_NAME" >&2 || true
            return 1
        fi
        sleep 2
    done
    echo "Android did not boot within ${BOOT_TIMEOUT}s" >&2
    docker logs "$CONTAINER_NAME" >&2 || true
    return 1
}

wait_for_bluetooth() {
    local deadline=$((SECONDS + 45)) output log_output hci_ready=0 manager_ready=0
    adb_shell setprop persist.bluetooth.btsnooplogmode full >/dev/null 2>&1 || true
    adb_shell cmd bluetooth_manager enable >/dev/null 2>&1 || \
        adb_shell svc bluetooth enable >/dev/null 2>&1 || true
    while (( SECONDS < deadline )); do
        output=$(adb_shell dumpsys bluetooth_manager 2>/dev/null || true)
        log_output=$(adb_shell logcat -d -v brief 2>/dev/null || true)
        grep -Eq 'state: ON|enabled: true' <<<"$output" && manager_ready=1
        grep -q 'HCI device ready' <<<"$log_output" && hci_ready=1
        if [[ $manager_ready == 1 && $hci_ready == 1 ]]; then
            return 0
        fi
        sleep 2
    done
    adb_shell dumpsys bluetooth_manager >&2 || true
    adb_shell logcat -d -v brief | grep -Ei 'bluetooth|btlinux|bt_hci|hci device' >&2 || true
    echo "Bluetooth readiness failed (manager=$manager_ready, btlinux_hci=$hci_ready)" >&2
    return 1
}

collect_hci_snoop() {
    local remote output=$STATE_DIR/btsnoop_hci.log
    for remote in \
        /data/misc/bluetooth/logs/btsnoop_hci.log \
        /data/misc/bluedroid/btsnoop_hci.log; do
        if adb_shell test -s "$remote" >/dev/null 2>&1; then
            adb -s "$ADB_SERIAL" exec-out cat "$remote" >"$output"
            note "HCI snoop saved to $output"
            return 0
        fi
    done
    return 1
}

verify_native_bridge() {
    local abilist bridge apk=$STATE_DIR/redroid-arm64-smoke.apk
    local deadline output package_abi=''
    abilist=$(adb_shell getprop ro.product.cpu.abilist | tr -d '\r')
    note "Android ABI list: $abilist"
    [[ $abilist == *arm64-v8a* ]] || die "ARM64 ABI is not advertised"
    bridge=$(adb_shell getprop ro.dalvik.vm.native.bridge | tr -d '\r')
    [[ $bridge == "$REDROID_NATIVE_BRIDGE" ]] || \
        die "native bridge is '$bridge', expected '$REDROID_NATIVE_BRIDGE'"

    if [[ ! -r $apk ]]; then
        note "ARM64 bridge properties verified (smoke APK unavailable)"
        return 0
    fi

    adb -s "$ADB_SERIAL" uninstall dev.redroid.arm64smoke >/dev/null 2>&1 || true
    adb -s "$ADB_SERIAL" install --no-incremental -r "$apk" >/dev/null || \
        die "ARM64 smoke APK installation failed"
    adb_shell am start -W -n dev.redroid.arm64smoke/.MainActivity >/dev/null || \
        die "ARM64 smoke app did not launch"
    deadline=$((SECONDS + 20))
    while (( SECONDS < deadline )); do
        output=$(adb_shell logcat -d -v brief -s RedroidArm64Smoke:I '*:S' 2>/dev/null || true)
        if grep -q 'ARM64 native bridge: ok' <<<"$output"; then
            package_abi=$(adb_shell dumpsys package dev.redroid.arm64smoke 2>/dev/null \
                | sed -n 's/.*primaryCpuAbi=//p' | head -1 | tr -d '\r')
            break
        fi
        sleep 1
    done
    adb -s "$ADB_SERIAL" uninstall dev.redroid.arm64smoke >/dev/null 2>&1 || true
    [[ $package_abi == arm64-v8a ]] || \
        die "ARM64 app native-bridge smoke failed (package ABI='$package_abi')"
    note "ARM64 app native bridge verified"
}

verify_network_unchanged() {
    local current_address current_route current_policy current_firewall
    # shellcheck disable=SC1090
    source "$STATE_FILE"
    current_address=$(network_hash address)
    current_route=$(network_hash route)
    current_policy=$(network_hash policy)
    current_firewall=$(network_hash firewall)
    [[ $current_address == "$ADDRESS_HASH" ]] || die "host interface addresses changed during Android boot"
    [[ $current_route == "$ROUTE_HASH" ]] || die "host routes changed during Android boot"
    [[ $current_policy == "$POLICY_HASH" ]] || die "host policy routing changed during Android boot"
    [[ $current_firewall == "$FIREWALL_RUNTIME_HASH" ]] || \
        die "host firewall rules changed unexpectedly during Android boot"
}

cmd_start() {
    case ${1:-} in
        '') ;;
        --no-bt) BT_ENABLE=0 ;;
        *) die "usage: $0 start [--no-bt]" ;;
    esac
    acquire_lock
    require_runtime_tools
    [[ $BT_ENABLE == 0 ]] || require_bt_tools
    if container_running; then
        [[ -r $STATE_FILE ]] || die "running container '$CONTAINER_NAME' has no lifecycle state; stop it before continuing"
        [[ $(docker inspect -f '{{(index (index .NetworkSettings.Ports "5555/tcp") 0).HostIp}}' \
            "$CONTAINER_NAME" 2>/dev/null || true) == "$ADB_HOST" ]] || \
            die "running container '$CONTAINER_NAME' does not expose ADB on loopback only"
        note "container '$CONTAINER_NAME' is already running"
        return 0
    fi
    if container_exists || [[ -r $STATE_FILE ]]; then
        note "Recovering an interrupted previous run"
        capture_stop_active
        stop_container
        restore_host_state
        [[ ${RESTORE_HOST_OK:-1} == 1 ]] || \
            die "cannot start because host network state differs from the previous snapshot"
    fi
    preflight

    local bluez_active=0 bluez_masked=0 bt_powered=0 adapter_index=''
    local modprobe_value address_hash route_hash policy_hash firewall_hash enabled_state
    if [[ $BT_ENABLE == 1 ]]; then
        systemctl is-active --quiet bluetooth.service && bluez_active=1
        enabled_state=$(systemctl is-enabled bluetooth.service 2>/dev/null || true)
        [[ $enabled_state == masked || $enabled_state == masked-runtime ]] && bluez_masked=1
        adapter_index=${BT_ADAPTER#hci}
        [[ $adapter_index =~ ^[0-9]+$ ]] || die "BT_ADAPTER must look like hci0"
        sudo btmgmt --index "$adapter_index" info 2>/dev/null \
            | grep -Eq 'current settings:.*powered' && bt_powered=1
    fi
    modprobe_value=$(cat /proc/sys/kernel/modprobe)
    address_hash=$(network_hash address)
    route_hash=$(network_hash route)
    policy_hash=$(network_hash policy)
    firewall_hash=$(network_hash firewall)
    write_state "$bluez_active" "$bluez_masked" "$bt_powered" "$modprobe_value" \
        "$address_hash" "$route_hash" "$policy_hash" "$firewall_hash"

    trap rollback_start EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    if [[ $BT_ENABLE == 1 ]]; then
        note "Stopping BlueZ and reserving $BT_ADAPTER for Android"
        sudo systemctl mask --runtime bluetooth.service dbus-org.bluez.service >/dev/null
        sudo systemctl stop bluetooth.service
        systemctl is-active --quiet bluetooth.service && die "BlueZ restarted while reserving $BT_ADAPTER"
        sudo btmgmt --index "$adapter_index" power off >/dev/null 2>&1 || true
    fi
    mkdir -p "$REDROID_DATA_DIR"

    # Without the host netns mount the btlinux HAL exits at once, so it can
    # never open (and steal) the host adapter.
    local netns_mount=()
    [[ $BT_ENABLE == 0 ]] || \
        netns_mount=(--mount "type=bind,source=$HOST_NETNS_SOURCE,target=/redroid-host-netns,readonly")

    note "Starting $CONTAINER_NAME with isolated Android networking"
    docker run -d \
        --name "$CONTAINER_NAME" \
        --hostname "$CONTAINER_NAME" \
        --privileged \
        --network bridge \
        --publish "$ADB_HOST:$ADB_PORT:5555" \
        "${netns_mount[@]}" \
        --volume "$REDROID_DATA_DIR:/data" \
        "$LOCAL_IMAGE" \
        androidboot.redroid_width="$REDROID_WIDTH" \
        androidboot.redroid_height="$REDROID_HEIGHT" \
        androidboot.redroid_dpi="$REDROID_DPI" \
        androidboot.redroid_fps="$REDROID_FPS" \
        androidboot.redroid_gpu_mode="$REDROID_GPU_MODE" \
        androidboot.use_memfd=1 \
        ro.product.cpu.abilist=x86_64,x86,arm64-v8a \
        ro.product.cpu.abilist64=x86_64,arm64-v8a \
        ro.product.cpu.abilist32=x86 \
        ro.dalvik.vm.isa.arm64=x86_64 \
        ro.enable.native.bridge.exec=1 \
        ro.dalvik.vm.native.bridge="$REDROID_NATIVE_BRIDGE" >/dev/null

    printf 'FIREWALL_RUNTIME_HASH=%q\n' "$(network_hash firewall)" >>"$STATE_FILE"

    wait_for_android
    verify_network_unchanged
    [[ $BT_ENABLE == 0 ]] || wait_for_bluetooth
    verify_native_bridge
    trap - EXIT INT TERM
    note "redroid is ready; run './redroid.sh screen'"
}

cmd_stop() {
    local bt_managed=0
    acquire_lock
    require_runtime_tools
    bt_managed_in_state && bt_managed=1
    [[ $bt_managed == 0 ]] || require_bt_tools
    capture_stop_active
    note "Stopping redroid"
    stop_container
    restore_host_state
    [[ $bt_managed == 0 ]] || stop_check_bluetooth
    [[ ${RESTORE_HOST_OK:-1} == 1 ]] || die "host network state was not fully restored"
    [[ $bt_managed == 0 ]] || stop_report_bluetooth
}

stop_check_bluetooth() {
    if [[ -d /sys/class/bluetooth/$BT_ADAPTER ]]; then
        sudo btmgmt --index "${BT_ADAPTER#hci}" info >/dev/null || \
            die "host adapter '$BT_ADAPTER' did not become usable"
    fi
    if [[ ${RESTORED_BT_SHOULD_BE_POWERED:-0} == 1 ]]; then
        adapter_is_powered || die "host adapter '$BT_ADAPTER' is not powered"
    fi
}

stop_report_bluetooth() {
    if systemctl is-active --quiet bluetooth.service; then
        note "Host Bluetooth restored"
    else
        note "Host Bluetooth remains stopped because it was stopped before redroid started"
    fi
}

cmd_screen() {
    local scrcpy_args=(-s "$ADB_SERIAL" --stay-awake)
    need adb
    need scrcpy
    adb connect "$ADB_SERIAL" >/dev/null
    [[ $(adb_shell getprop sys.boot_completed 2>/dev/null | tr -d '\r') == 1 ]] || \
        die "Android is not booted"
    if scrcpy --help 2>&1 | grep -q -- '--audio-codec'; then
        scrcpy_args+=(
            --audio-codec=aac
            --audio-encoder=OMX.google.aac.encoder
        )
    else
        note "This scrcpy version has no audio forwarding; starting video and input only"
    fi
    exec scrcpy "${scrcpy_args[@]}"
}

cmd_status() {
    local container_status
    need docker
    container_status=$(docker inspect -f '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null || true)
    [[ -n $container_status ]] || container_status=absent
    echo "container: $container_status"
    if bt_managed_in_state; then
        echo "bluez:     $(systemctl is-active bluetooth.service 2>/dev/null || true)"
        echo "adapter:   $([[ -d /sys/class/bluetooth/$BT_ADAPTER ]] && echo present || echo absent)"
    fi
    capture_active && echo "capture:   $(<"$CAPTURE_CURRENT")" || echo "capture:   none"
    adb connect "$ADB_SERIAL" >/dev/null 2>&1 || true
    if adb -s "$ADB_SERIAL" get-state >/dev/null 2>&1; then
        echo "android:   boot_completed=$(adb_shell getprop sys.boot_completed | tr -d '\r')"
        echo "abis:      $(adb_shell getprop ro.product.cpu.abilist | tr -d '\r')"
        if bt_managed_in_state; then
            if grep -q 'HCI device ready' <<<"$(adb_shell logcat -d -v brief 2>/dev/null || true)"; then
                echo "btlinux:   HCI device ready"
            else
                echo "btlinux:   no HCI-ready marker"
            fi
            adb_shell dumpsys bluetooth_manager | grep -E 'enabled:|state:|address:|name:' | head -8
        fi
    else
        echo "android:   adb disconnected"
    fi
}

cmd_logs() {
    need docker
    need adb
    docker logs "$CONTAINER_NAME" 2>&1 || true
    adb connect "$ADB_SERIAL" >/dev/null 2>&1 || true
    if adb -s "$ADB_SERIAL" get-state >/dev/null 2>&1; then
        echo "--- Android Bluetooth logcat ---"
        adb_shell logcat -d -v threadtime | grep -Ei 'bluetooth|btlinux|bt_hci|hci device|nativebridge' || true
        echo "--- Bluetooth manager ---"
        adb_shell dumpsys bluetooth_manager || true
        collect_hci_snoop || echo "HCI snoop file is not available yet"
    fi
}

CAPTURE_CURRENT=$STATE_DIR/capture.current

capture_active() {
    [[ -r $CAPTURE_CURRENT ]]
}

# True when PID still names a live process called NAME; guards against
# signalling a recycled PID from a stale session.
proc_is() {
    [[ -n $2 && -r /proc/$2/comm && $(< "/proc/$2/comm") == "$1" ]]
}

# Android 14 reads trust anchors from the conscrypt APEX, older releases from
# /system. Both are writable overlays in redroid, so copy the mitmproxy CA into
# each. The copy lives in the container layer and is redone on every capture
# start.
install_mitm_ca() {
    local ca=$HOME/.mitmproxy/mitmproxy-ca-cert.pem hash dir
    [[ -r $ca ]] || { echo "warning: mitmproxy CA not found; HTTPS will not decode" >&2; return 0; }
    hash=$(openssl x509 -inform PEM -subject_hash_old -in "$ca" -noout)
    adb -s "$ADB_SERIAL" push "$ca" "/data/local/tmp/$hash.0" >/dev/null
    for dir in /apex/com.android.conscrypt/cacerts /system/etc/security/cacerts; do
        adb_shell su 0 sh -c "'cp /data/local/tmp/$hash.0 $dir/ && chmod 644 $dir/$hash.0'" || \
            echo "warning: could not install the mitmproxy CA into $dir" >&2
    done
    adb_shell rm -f "/data/local/tmp/$hash.0"
    adb_shell test -e "/apex/com.android.conscrypt/cacerts/$hash.0" || \
        echo "warning: mitmproxy CA is not in the Android trust store; HTTPS will not decode" >&2
}

start_mitmproxy() {
    local sess=$1 gateway=$2 port=$MITM_PORT attempts=0
    while (( port <= 65535 && attempts < 100 )); do
        note "Starting mitmproxy on $gateway:$port"
        SSLKEYLOGFILE=$sess/sslkeylog.txt mitmdump --mode regular \
            --listen-host "$gateway" --listen-port "$port" \
            --set block_global=false -w "$sess/flows.mitm" \
            >"$sess/mitm.log" 2>&1 9>&- &
        echo $! >"$sess/mitm.pid"
        sleep 2
        if proc_is mitmdump "$(<"$sess/mitm.pid")"; then
            echo "$gateway:$port" >"$sess/proxy"
            return 0
        fi
        grep -qi 'address already in use' "$sess/mitm.log" || \
            die "mitmproxy failed to start (see $sess/mitm.log)"
        port=$((port + 1))
        attempts=$((attempts + 1))
    done
    die "no free proxy port found from $MITM_PORT"
}

capture_start_abort() {
    local exit_code=$?
    trap - EXIT
    (( exit_code == 0 )) || capture_stop_active
    exit "$exit_code"
}

capture_start() {
    local use_mitm=1 sess netns_pid gateway user
    case ${1:-} in
        '') ;;
        --no-mitm) use_mitm=0 ;;
        *) die "usage: $0 capture start [--no-mitm]" ;;
    esac
    need tcpdump
    need nsenter
    need timeout
    [[ $use_mitm == 0 ]] || { need mitmdump; need openssl; }
    container_running || die "container '$CONTAINER_NAME' is not running; run './redroid.sh start'"
    capture_active && die "a capture is already running ($(<"$CAPTURE_CURRENT")); run '$0 capture stop'"

    sess=$CAPTURE_DIR/$(date -u +%Y%m%d-%H%M%SZ)
    mkdir -p "$sess"
    printf '%s\n' "$sess" >"$CAPTURE_CURRENT"
    trap capture_start_abort EXIT
    note "Capture session: $sess"

    # tcpdump runs inside the container's network namespace so it sees every
    # packet (HTTPS, UDP/P2P, DNS, ...); it then drops to the invoking user so
    # the pcap is user-owned. fd 9 is closed so the lifecycle lock is not inherited.
    sudo -v
    netns_pid=$(docker inspect -f '{{.State.Pid}}' "$CONTAINER_NAME")
    user=$(id -un)
    # The log redirect is deliberately made by the invoking user, not by sudo.
    # shellcheck disable=SC2024
    sudo sh -c 'echo $$ >"$1"; shift; exec "$@"' sh "$sess/tcpdump.pid" \
        nsenter -t "$netns_pid" -n \
        tcpdump -i any -U -Z "$user" -w "$sess/full.pcap" 'not tcp port 5555' \
        >"$sess/tcpdump.log" 2>&1 9>&- &
    sleep 2
    proc_is tcpdump "$(cat "$sess/tcpdump.pid" 2>/dev/null)" || \
        die "tcpdump failed to start (see $sess/tcpdump.log)"

    if [[ $use_mitm == 1 ]]; then
        gateway=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.Gateway}}{{end}}' "$CONTAINER_NAME")
        [[ -n $gateway ]] || die "cannot resolve the container's Docker gateway"
        start_mitmproxy "$sess" "$gateway"
        adb connect "$ADB_SERIAL" >/dev/null 2>&1 || true
        install_mitm_ca
        note "Pointing Android at the proxy ($(<"$sess/proxy"))"
        adb_shell settings put global http_proxy "$(<"$sess/proxy")"
    else
        note "mitmproxy disabled; capturing raw packets only"
    fi
    trap - EXIT
    note "Capturing. Use the app, then run '$0 capture stop'"
}

capture_stop_active() {
    local sess pid
    capture_active || return 0
    sess=$(<"$CAPTURE_CURRENT")
    note "Stopping capture: $sess"

    if [[ -e $sess/proxy ]]; then
        timeout 10 adb -s "$ADB_SERIAL" shell settings put global http_proxy :0 \
            >/dev/null 2>&1 || echo "warning: could not clear the Android proxy" >&2
        pid=$(cat "$sess/mitm.pid" 2>/dev/null || true)
        ! proc_is mitmdump "$pid" || kill "$pid" 2>/dev/null || true
    fi
    pid=$(cat "$sess/tcpdump.pid" 2>/dev/null || true)
    if proc_is tcpdump "$pid"; then
        sudo kill -INT "$pid" || true
        timeout 10 sh -c "while [ -d /proc/$pid ]; do sleep 0.2; done" || true
    fi
    rm -f "$sess/tcpdump.pid" "$sess/mitm.pid" "$CAPTURE_CURRENT"

    # Injecting mitmproxy's TLS keys lets Wireshark decrypt the HTTPS legs
    # while non-proxied traffic stays raw.
    if [[ -s $sess/sslkeylog.txt && -s $sess/full.pcap ]] && command -v editcap >/dev/null 2>&1; then
        editcap --inject-secrets "tls,$sess/sslkeylog.txt" \
            "$sess/full.pcap" "$sess/full-decrypted.pcapng" 2>/dev/null || \
            echo "warning: TLS key injection failed; pair full.pcap with sslkeylog.txt manually" >&2
    fi
    note "Artifacts in $sess:"
    find "$sess" -maxdepth 1 -type f -printf '    %-24f %k KiB\n'
    [[ ! -s $sess/flows.mitm ]] || note "Read HTTP: mitmweb --rfile $sess/flows.mitm"
    if [[ -s $sess/full-decrypted.pcapng ]]; then
        note "Read all:  wireshark $sess/full-decrypted.pcapng"
    else
        note "Read all:  wireshark $sess/full.pcap"
    fi
}

cmd_capture() {
    local action=${1:-}
    [[ $# -eq 0 ]] || shift
    case $action in
        start) acquire_lock; capture_start "$@" ;;
        stop)
            acquire_lock
            capture_active || die "no active capture"
            capture_stop_active
            ;;
        status) capture_active && echo "capturing: $(<"$CAPTURE_CURRENT")" || echo "no active capture" ;;
        *) die "usage: $0 capture {start [--no-mitm]|stop|status}" ;;
    esac
}

cmd_install() {
    local files=() arg f
    [[ $# -gt 0 ]] || die "usage: $0 install <apk|dir>..."
    need adb
    for arg; do
        if [[ -d $arg ]]; then files+=("$arg"/*.apk); else files+=("$arg"); fi
    done
    for f in "${files[@]}"; do
        [[ -f $f ]] || die "no such APK: $f"
    done
    adb connect "$ADB_SERIAL" >/dev/null 2>&1 || true
    # A directory of split APKs (base + split_config.*) installs as one app.
    if (( ${#files[@]} == 1 )); then
        adb -s "$ADB_SERIAL" install -r -g "${files[0]}"
    else
        adb -s "$ADB_SERIAL" install-multiple -r -g "${files[@]}"
    fi
}

usage() {
    cat <<'EOF'
Usage: ./redroid.sh {setup|start|stop|screen|status|logs|install|capture}

  setup    Install missing Arch/Debian/Ubuntu tools and build the image
  start    Boot redroid; give hci0 to Android unless --no-bt (or BT_ENABLE=0)
  stop     Stop redroid (ending any capture) and restore the host
  screen   Open the Android display with scrcpy
  status   Show container, host Bluetooth, Android, ABI, and capture status
  logs     Collect container and Android Bluetooth diagnostics
  install  Install an APK, several split APKs, or a directory of splits
  capture  capture start [--no-mitm] | stop | status: pcap + decoded HTTPS
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
    capture) shift; cmd_capture "$@" ;;
    *) usage; exit 2 ;;
esac
