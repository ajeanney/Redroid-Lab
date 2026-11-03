# shellcheck shell=bash
# `install`, `pull`, `launch`: APKs in and out of the guest.

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
    adb_connect
    # A directory of split APKs (base + split_config.*) installs as one app.
    if (( ${#files[@]} == 1 )); then
        adb_dev install -r -g "${files[0]}"
    else
        adb_dev install-multiple -r -g "${files[@]}"
    fi
}

cmd_pull() {
    local package=${1:-} option use_apktool=0 use_jadx=0 paths path name output apk
    local analysis_failed=0 use_report=0 decode_failed=0
    local remote_paths=() apks=() decoded=()
    local -A names=()
    [[ $# -gt 0 ]] || die "usage: $0 pull <package> [--apktool] [--jadx] [--report]"
    shift
    validate_package "$package"
    for option; do
        case $option in
            --apktool) use_apktool=1 ;;
            --jadx) use_jadx=1 ;;
            --report) use_report=1; use_apktool=1 ;;
            *) die "usage: $0 pull <package> [--apktool] [--jadx] [--report]" ;;
        esac
    done
    need adb flock
    [[ $use_apktool == 0 ]] || need apktool
    [[ $use_jadx == 0 ]] || need jadx
    [[ $use_report == 0 ]] || need python3
    acquire_lock
    adb connect "$ADB_SERIAL" >/dev/null || die "cannot connect to Android at $ADB_SERIAL"
    paths=$(adb_shell pm path "$package" | tr -d '\r') || \
        die "could not query APK paths for $package"
    [[ -n $paths ]] || die "package is not installed: $package"
    while IFS= read -r path; do
        [[ $path == package:/*.apk ]] || die "unexpected APK path: $path"
        path=${path#package:}
        name=${path##*/}
        [[ $name =~ ^[A-Za-z0-9_][A-Za-z0-9._-]*\.apk$ ]] || die "unsafe APK filename: $name"
        [[ -z ${names[$name]+set} ]] || die "duplicate APK filename: $name"
        names[$name]=1
        remote_paths+=("$path")
    done <<<"$paths"

    umask 077
    output=$(stamped_dir "$PULL_DIR/$package")
    note "Pull directory: $output"
    for path in "${remote_paths[@]}"; do
        name=${path##*/}
        adb_dev pull "$path" "$output/$name.part" || \
            die "APK pull failed; incomplete output retained at $output"
        [[ -f $output/$name.part && -s $output/$name.part ]] || \
            die "empty or invalid APK pulled; incomplete output retained at $output"
        mv -- "$output/$name.part" "$output/$name"
        apks+=("$output/$name")
    done
    note "Pulled ${#apks[@]} APK(s) to $output"
    # Analysis only uses host files and must not block Android lifecycle commands.
    exec 9>&-
    if [[ $use_apktool == 1 ]]; then
        for apk in "${apks[@]}"; do
            name=${apk##*/}
            decoded+=("$output/apktool/${name%.apk}")
            if ! apktool d "$apk" -o "$output/apktool/${name%.apk}"; then
                warn "apktool failed for $name"
                analysis_failed=1
                decode_failed=1
            fi
        done
    fi
    if [[ $use_jadx == 1 ]]; then
        if ! jadx -d "$output/jadx" "${apks[@]}"; then
            warn "jadx failed"
            analysis_failed=1
        fi
    fi
    if [[ $use_report == 1 ]]; then
        if [[ $decode_failed == 1 ]] || ! python3 "$SCRIPT_DIR/lib/manifest_report.py" "$output/report.json" "${decoded[@]}"; then
            warn "manifest report failed"
            analysis_failed=1
        else
            note "Attack surface report: $output/report.json"
        fi
    fi
    [[ $analysis_failed == 0 ]] || die "static analysis failed; APKs and analysis output retained at $output"
}

cmd_launch() {
    local package=${1:-} activity
    [[ -n $package ]] || die "usage: $0 launch <package>"
    need adb
    adb_connect
    # am start on the resolved activity is reliable; monkey is not under ARM translation.
    activity=$(adb_shell cmd package resolve-activity --brief "$package" | tail -1 | tr -d '\r')
    [[ $activity == */* ]] || die "no launcher activity found for '$package'"
    adb_shell am start -n "$activity"
}
