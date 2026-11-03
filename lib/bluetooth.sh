# shellcheck shell=bash
# Host Bluetooth takeover and restore, plus Android-side Bluetooth checks.

require_bt_tools() {
    need systemctl btmgmt rfkill
}

# True when the lifecycle state on disk says this run took over Bluetooth.
# States written before BT_MANAGED existed always did.
bt_managed_in_state() {
    [[ -r $STATE_FILE ]] && ! grep -q '^BT_MANAGED=0$' "$STATE_FILE"
}

bt_mgmt() {
    sudo btmgmt --index "${BT_ADAPTER#hci}" "$@"
}

validate_adapter_identity() {
    local interface_path usb_path usb_id
    [[ -d /sys/class/bluetooth/$BT_ADAPTER ]] || \
        die "Bluetooth adapter '$BT_ADAPTER' is unavailable"
    [[ $BT_ADAPTER =~ ^hci[0-9]+$ ]] || \
        die "BT_ADAPTER must look like hci0"
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
            die "'$BT_ADAPTER' is USB $usb_id, expected $BT_EXPECTED_USB_ID"
    fi
}

adapter_is_powered() {
    bt_mgmt info 2>/dev/null | grep -Eq 'current settings:.*powered'
}

power_adapter_on() {
    local attempt=0
    while (( attempt < 3 )); do
        ((attempt += 1))
        bt_mgmt power on >/dev/null 2>&1 || true
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

# Print "<bluez_active> <bluez_masked> <adapter_powered>" (0/1 each) for write_state.
bt_host_state() {
    local active=0 masked=0 powered=0 enabled_state
    systemctl is-active --quiet bluetooth.service && active=1
    enabled_state=$(systemctl is-enabled bluetooth.service 2>/dev/null || true)
    [[ $enabled_state == masked || $enabled_state == masked-runtime ]] && masked=1
    adapter_is_powered && powered=1
    echo "$active $masked $powered"
}

bt_reserve_adapter() {
    note "Stopping BlueZ and reserving $BT_ADAPTER for Android"
    sudo systemctl mask --runtime bluetooth.service dbus-org.bluez.service >/dev/null
    sudo systemctl stop bluetooth.service
    ! systemctl is-active --quiet bluetooth.service || die "BlueZ restarted while reserving $BT_ADAPTER"
    bt_mgmt power off >/dev/null 2>&1 || true
}

# Undo bt_reserve_adapter from the recorded state; clears RESTORE_HOST_OK on failure.
bt_restore_host() {
    local was_active=$1 was_masked=$2 was_powered=$3
    sudo rfkill unblock bluetooth || true
    if [[ $was_powered == 1 ]]; then
        RESTORED_BT_SHOULD_BE_POWERED=1
        if ! power_adapter_on && ! reset_bluetooth_adapter; then
            warn "host Bluetooth adapter could not be powered back on"
            # shellcheck disable=SC2034 # read by restore_host_state's callers
            RESTORE_HOST_OK=0
        fi
    fi
    if [[ $was_masked == 0 ]]; then
        sudo systemctl unmask --runtime bluetooth.service dbus-org.bluez.service \
            >/dev/null 2>&1 || true
    fi
    if [[ $was_active == 1 ]]; then
        sudo systemctl start bluetooth.service || true
    fi
}

stop_check_bluetooth() {
    if [[ -d /sys/class/bluetooth/$BT_ADAPTER ]]; then
        bt_mgmt info >/dev/null || \
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
            adb_dev exec-out cat "$remote" >"$output"
            note "HCI snoop saved to $output"
            return 0
        fi
    done
    return 1
}
