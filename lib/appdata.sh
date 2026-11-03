# shellcheck shell=bash
# `appdata`: private, live copies of user-0 app data and a diff of the last two.

cmd_appdata() {
    local action=${1:-} package=${2:-} output
    [[ $# == 2 && ( $action == pull || $action == diff ) ]] || \
        die "usage: $0 appdata {pull|diff} <package>"
    validate_package "$package"
    need python3 flock
    acquire_lock
    if [[ $action == diff ]]; then
        python3 "$SCRIPT_DIR/lib/appdata.py" diff "$APPDATA_DIR/$package"
        return
    fi
    need adb docker
    require_running
    adb_connect
    app_uid "$package" >/dev/null
    umask 077
    output=$(stamped_dir "$APPDATA_DIR/$package")
    note "App data directory: $output"
    # exec-out preserves tar bytes; root is confined to the Android guest.
    adb_dev exec-out su 0 tar -C "/data/data/$package" -cf - . | \
        python3 "$SCRIPT_DIR/lib/appdata.py" extract "$output/data.part" || \
        die "app data pull failed; incomplete output retained at $output"
    mv -- "$output/data.part" "$output/data"
    note "Live app data copied; concurrent writes may make databases inconsistent"
}
