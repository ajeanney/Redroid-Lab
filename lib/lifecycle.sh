# shellcheck shell=bash
# `start`, `stop`, `screen`, `status`, `logs`: container lifecycle and host state.

preflight() {
    require_runtime_tools
    docker info >/dev/null 2>&1 || die "Docker daemon is unavailable"
    docker image inspect "$LOCAL_IMAGE" >/dev/null 2>&1 || \
        die "image '$LOCAL_IMAGE' is missing; run './redroid.sh setup'"
    ensure_binder
    [[ $BT_ENABLE == 0 ]] || validate_adapter_identity
    [[ -e /dev/dri/renderD128 ]] || \
        die "Intel render node /dev/dri/renderD128 is unavailable"
    # -L: the magic /proc/1/ns/net link is not stat-able by non-root users;
    # Docker resolves it as root when bind-mounting.
    [[ $BT_ENABLE == 0 || -e $HOST_NETNS_SOURCE || -L $HOST_NETNS_SOURCE ]] || \
        die "host network namespace is unavailable at '$HOST_NETNS_SOURCE'"
    if ss -H -ltn "sport = :$ADB_PORT" | grep -q .; then
        die "TCP port $ADB_PORT is already in use"
    fi
    # Checked before any host change; a stale guard of ours is removed by `stop`.
    ! sudo nft list table inet "$NFT_TABLE" >/dev/null 2>&1 || \
        die "nftables table inet/$NFT_TABLE already exists; run './redroid.sh stop' or change NFT_TABLE"
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

# Print the network aspects whose hash differs from the expected address,
# route, policy and firewall hashes given in that order (empty = not checked).
network_changes() {
    local kind changed=()
    for kind in address route policy firewall; do
        [[ -z $1 || $(network_hash "$kind") == "$1" ]] || changed+=("$kind")
        shift
    done
    echo "${changed[*]}"
}

# Record everything `stop` must restore, before the host is touched.
write_state() {
    local bluez_active=0 bluez_masked=0 bt_powered=0
    local modprobe_value address_hash route_hash policy_hash firewall_hash
    [[ $BT_ENABLE == 0 ]] || read -r bluez_active bluez_masked bt_powered <<<"$(bt_host_state)"
    # Separate assignments so a failing probe aborts the start.
    modprobe_value=$(</proc/sys/kernel/modprobe)
    address_hash=$(network_hash address)
    route_hash=$(network_hash route)
    policy_hash=$(network_hash policy)
    firewall_hash=$(network_hash firewall)
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

ADB_GUARD_COMMENT=redroid-adb-guard

# Drop non-loopback packets for the ADB port addressed to this host, before
# Docker's DNAT: otherwise a LAN neighbour can reach the 127.0.0.1 publish by
# sending to 127.0.0.1 via this host. `create` fails atomically if the table exists.
install_adb_guard() {
    note "Restricting ADB port $ADB_PORT to loopback (nftables inet/$NFT_TABLE)"
    sudo nft -f - <<EOF
create table inet $NFT_TABLE { comment "$ADB_GUARD_COMMENT"; }
add chain inet $NFT_TABLE prerouting { type filter hook prerouting priority raw; policy accept; }
add rule inet $NFT_TABLE prerouting iifname != "lo" fib daddr type local tcp dport $ADB_PORT drop comment "redroid adb loopback only"
EOF
}

# Only delete the table install_adb_guard created; another owner's keeps its rules.
remove_adb_guard() {
    local rules
    rules=$(sudo nft list table inet "$NFT_TABLE" 2>/dev/null) || return 0
    if ! grep -Fq "comment \"$ADB_GUARD_COMMENT\"" <<<"$rules"; then
        warn "nftables table inet/$NFT_TABLE is not redroid's ADB guard; leaving it"
        return 0
    fi
    sudo nft delete table inet "$NFT_TABLE" || warn "could not remove nftables table inet/$NFT_TABLE"
}

restore_host_state() {
    local bluez_was_active=0 bluez_was_masked=0 bt_was_powered=0
    local modprobe_value='' have_state=0 address_hash='' route_hash=''
    local policy_hash='' firewall_before_hash='' bt_managed=1 changed
    RESTORE_HOST_OK=1
    # shellcheck disable=SC2034 # set by bt_restore_host, read by stop_check_bluetooth
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
        [[ $bt_managed == 0 ]] || \
            bt_restore_host "$bluez_was_active" "$bluez_was_masked" "$bt_was_powered"
        changed=$(network_changes "$address_hash" "$route_hash" "$policy_hash" "$firewall_before_hash")
        if [[ -n $changed ]]; then
            warn "host network state differs from its pre-start state ($changed)"
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
        adb_connect
        android_booted && return 0
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

verify_native_bridge() {
    local abilist bridge deadline output package_abi=''
    abilist=$(adb_shell getprop ro.product.cpu.abilist | tr -d '\r')
    note "Android ABI list: $abilist"
    [[ $abilist == *arm64-v8a* ]] || die "ARM64 ABI is not advertised"
    bridge=$(adb_shell getprop ro.dalvik.vm.native.bridge | tr -d '\r')
    [[ $bridge == "$REDROID_NATIVE_BRIDGE" ]] || \
        die "native bridge is '$bridge', expected '$REDROID_NATIVE_BRIDGE'"

    if [[ ! -r $SMOKE_APK ]]; then
        note "ARM64 bridge properties verified (smoke APK unavailable)"
        return 0
    fi

    adb_dev uninstall dev.redroid.arm64smoke >/dev/null 2>&1 || true
    adb_dev install --no-incremental -r "$SMOKE_APK" >/dev/null || \
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
    adb_dev uninstall dev.redroid.arm64smoke >/dev/null 2>&1 || true
    [[ $package_abi == arm64-v8a ]] || \
        die "ARM64 app native-bridge smoke failed (package ABI='$package_abi')"
    note "ARM64 app native bridge verified"
}

verify_network_unchanged() {
    local changed
    # shellcheck disable=SC1090
    source "$STATE_FILE"
    # :? fails closed if a hash is missing from the state file.
    changed=$(network_changes "${ADDRESS_HASH:?}" "${ROUTE_HASH:?}" "${POLICY_HASH:?}" \
        "${FIREWALL_RUNTIME_HASH:?}")
    [[ -z $changed ]] || die "host network state changed during Android boot ($changed)"
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
    write_state

    trap_exit rollback_start
    install_adb_guard
    [[ $BT_ENABLE == 0 ]] || bt_reserve_adapter
    mkdir -p "$REDROID_DATA_DIR"

    # Without the host netns mount the btlinux HAL exits at once, so it can
    # never open (and steal) the host adapter.
    local netns_mount=() identity_properties=()
    [[ -z $REDROID_MODEL ]] || identity_properties+=("ro.product.model=$REDROID_MODEL")
    [[ -z $REDROID_MANUFACTURER ]] || identity_properties+=("ro.product.manufacturer=$REDROID_MANUFACTURER")
    [[ -z $REDROID_BRAND ]] || identity_properties+=("ro.product.brand=$REDROID_BRAND")
    [[ -z $REDROID_DEVICE ]] || identity_properties+=("ro.product.device=$REDROID_DEVICE")
    [[ -z $REDROID_PRODUCT ]] || identity_properties+=("ro.product.name=$REDROID_PRODUCT")
    [[ -z $REDROID_FINGERPRINT ]] || identity_properties+=("ro.build.fingerprint=$REDROID_FINGERPRINT")
    [[ -z $REDROID_QEMU ]] || identity_properties+=("ro.kernel.qemu=$REDROID_QEMU")
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
        ro.dalvik.vm.native.bridge="$REDROID_NATIVE_BRIDGE" \
        ro.redroid.camera="$CAMERA_ENABLE" \
        ro.redroid.bt.hci="${BT_ADAPTER#hci}" \
        "${identity_properties[@]}" >/dev/null

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
    frida_forget
    stop_container
    restore_host_state
    [[ $bt_managed == 0 ]] || stop_check_bluetooth
    [[ ${RESTORE_HOST_OK:-1} == 1 ]] || die "host network state was not fully restored"
    [[ $bt_managed == 0 ]] || stop_report_bluetooth
}

cmd_screen() {
    local scrcpy_args=(-s "$ADB_SERIAL" --stay-awake)
    need adb scrcpy
    adb connect "$ADB_SERIAL" >/dev/null
    android_booted || die "Android is not booted"
    # Consume all help output so pipefail does not mistake SIGPIPE for missing audio support.
    if scrcpy --help 2>&1 | grep -- '--audio-codec' >/dev/null; then
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
    adb_connect
    if adb_dev get-state >/dev/null 2>&1; then
        echo "android:   boot_completed=$(adb_shell getprop sys.boot_completed | tr -d '\r')"
        echo "abis:      $(adb_shell getprop ro.product.cpu.abilist | tr -d '\r')"
        frida_running && echo "frida:     running on 127.0.0.1:$FRIDA_PORT" || echo "frida:     stopped"
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
    need docker adb
    docker logs "$CONTAINER_NAME" 2>&1 || true
    adb_connect
    if adb_dev get-state >/dev/null 2>&1; then
        echo "--- Android Bluetooth logcat ---"
        adb_shell logcat -d -v threadtime | grep -Ei 'bluetooth|btlinux|bt_hci|hci device|nativebridge' || true
        echo "--- Bluetooth manager ---"
        adb_shell dumpsys bluetooth_manager || true
        collect_hci_snoop || echo "HCI snoop file is not available yet"
    fi
}
