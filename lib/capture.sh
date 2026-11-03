# shellcheck shell=bash
# `capture`: tcpdump in Android's netns plus explicit or transparent mitmproxy.

# Inner shell commands (expanded there, not here):
# PIDFILE_EXEC records the PID of the process it becomes, for later signalling;
# NETNS_GUARD re-checks the netns inode after nsenter, so a recycled PID can
# never run the command in another namespace.
# shellcheck disable=SC2016
PIDFILE_EXEC='echo $$ >"$1"; shift; exec "$@"'
# shellcheck disable=SC2016
NETNS_GUARD='[ "$(stat -Lc %i /proc/self/ns/net)" = "$1" ] || exit 1; shift; exec "$@"'

capture_active() {
    [[ -r $CAPTURE_CURRENT ]]
}

# True when PID still names a live process called NAME; guards against
# signalling a recycled PID from a stale session.
proc_is() {
    [[ -n $2 && -r /proc/$2/comm && $(< "/proc/$2/comm") == "$1" ]]
}

wait_pid_exit() {
    timeout 10 sh -c "while [ -d /proc/$1 ]; do sleep 0.2; done"
}

# Android 14 reads trust anchors from the conscrypt APEX, older releases from
# /system. Both are writable overlays in redroid, so copy the mitmproxy CA into
# each. The copy lives in the container layer and is redone on every capture
# start.
install_mitm_ca() {
    local ca=$HOME/.mitmproxy/mitmproxy-ca-cert.pem hash dir
    [[ -r $ca ]] || { warn "mitmproxy CA not found; HTTPS will not decode"; return 0; }
    hash=$(openssl x509 -inform PEM -subject_hash_old -in "$ca" -noout)
    adb_dev push "$ca" "/data/local/tmp/$hash.0" >/dev/null
    for dir in /apex/com.android.conscrypt/cacerts /system/etc/security/cacerts; do
        adb_shell su 0 sh -c "'cp /data/local/tmp/$hash.0 $dir/ && chmod 644 $dir/$hash.0'" || \
            warn "could not install the mitmproxy CA into $dir"
    done
    adb_shell rm -f "/data/local/tmp/$hash.0"
    adb_shell test -e "/apex/com.android.conscrypt/cacerts/$hash.0" || \
        warn "mitmproxy CA is not in the Android trust store; HTTPS will not decode"
}

start_mitmproxy() {
    local sess=$1 gateway=$2 mode=${3:-regular} netns_pid=${4:-} port=$MITM_PORT attempts=0
    local command=() modes=()
    while (( port <= 65535 && attempts < 100 )); do
        if [[ $mode == transparent ]]; then
            : >"$sess/mitm.pid"
            command=(sudo sh -c "$PIDFILE_EXEC" sh "$sess/mitm.pid"
                nsenter -t "$netns_pid" -n sh -c "$NETNS_GUARD"
                sh "$(<"$sess/netns.id")" setpriv --reuid "$(id -u)" --regid "$MITM_GID"
                --clear-groups --bounding-set=-all --no-new-privs
                env "HOME=$HOME" "PATH=$PATH" "SSLKEYLOGFILE=$sess/sslkeylog.txt" "$(command -v mitmdump)")
            modes=(--mode "transparent@127.0.0.1:$port" --mode "transparent@::1:$port")
        else
            command=(env "SSLKEYLOGFILE=$sess/sslkeylog.txt" mitmdump)
            modes=(--mode regular --listen-host "$gateway" --listen-port "$port")
        fi
        note "Starting mitmproxy on $gateway:$port"
        "${command[@]}" "${modes[@]}" \
            --set block_global=false -w "$sess/flows.mitm" \
            >"$sess/mitm.log" 2>&1 9>&- &
        [[ $mode == transparent ]] || echo $! >"$sess/mitm.pid"
        sleep 2
        if proc_is mitmdump "$(cat "$sess/mitm.pid" 2>/dev/null)"; then
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

# Check again after entering: a recycled PID must never select the host netns.
capture_netns_exec() {
    local sess=$1 expected pid
    shift
    [[ -r $sess/netns.id ]] || return 1
    expected=$(<"$sess/netns.id")
    [[ $expected =~ ^[0-9]+$ && $expected != "$(sudo stat -Lc %i /proc/1/ns/net)" ]] || return 1
    pid=$(sudo lsns --type net --noheadings --output NS,PID \
        | awk -v expected="$expected" '$1 == expected {print $2; exit}') || return 1
    [[ $pid =~ ^[1-9][0-9]*$ ]] || return 2
    sudo nsenter -t "$pid" -n sh -c "$NETNS_GUARD" sh "$expected" "$@"
}

capture_install_rules() {
    local sess=$1 port=${2:-} tables uid_match=''
    if [[ -r $sess/app.uid ]]; then
        uid_match="meta skuid $(<"$sess/app.uid") "
    fi
    tables=$(capture_netns_exec "$sess" nft list tables) || die "cannot inspect capture namespace"
    ! grep -Fxq "table inet $CAPTURE_NFT_TABLE" <<<"$tables" || \
        die "capture nftables table already exists: $CAPTURE_NFT_TABLE"
    printf '%s\n' "$CAPTURE_NFT_TABLE" >"$sess/redirect.table"
    {
        cat <<EOF
create table inet $CAPTURE_NFT_TABLE { comment "redroid-capture-${sess##*/}"; }
add chain inet $CAPTURE_NFT_TABLE quic { type filter hook output priority -120; policy accept; }
add rule inet $CAPTURE_NFT_TABLE quic ${uid_match}udp dport 443 drop
EOF
        if [[ -n $port ]]; then
            cat <<EOF
add chain inet $CAPTURE_NFT_TABLE output { type nat hook output priority -110; policy accept; }
add rule inet $CAPTURE_NFT_TABLE output meta skgid $MITM_GID return
add rule inet $CAPTURE_NFT_TABLE output ip daddr 127.0.0.0/8 return
add rule inet $CAPTURE_NFT_TABLE output ip6 daddr ::1 return
add rule inet $CAPTURE_NFT_TABLE output ${uid_match}tcp dport { 80, 443 } redirect to :$port
EOF
        fi
    } | capture_netns_exec "$sess" nft -f -
}

capture_remove_redirect() {
    local sess=$1 table tables rules result=0
    [[ -r $sess/redirect.table ]] || return 0
    table=$(<"$sess/redirect.table")
    [[ $table =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
    tables=$(capture_netns_exec "$sess" nft list tables) || result=$?
    # With no process left in this namespace, its unpinned rules have died too.
    if [[ $result != 2 ]]; then
        [[ $result == 0 ]] || return 1
        if grep -Fxq "table inet $table" <<<"$tables"; then
            rules=$(capture_netns_exec "$sess" nft list table inet "$table") || return 1
            grep -Fq "comment \"redroid-capture-${sess##*/}\"" <<<"$rules" || return 1
            capture_netns_exec "$sess" nft delete table inet "$table" || return 1
        fi
    fi
    rm -f "$sess/redirect.table"
}

capture_restore_module() {
    local sess=$1
    [[ -r $sess/module.loaded ]] || return 0
    # Only this leaf module was introduced; never unload its shared dependencies.
    if [[ -r /sys/module/nft_redir/refcnt ]]; then
        sudo rmmod nft_redir || return 1
    fi
    rm -f "$sess/module.loaded"
}

# Put back the Android proxy setting recorded at start; fails if adb cannot.
capture_restore_proxy() {
    local sess=$1 previous
    if [[ -r $sess/proxy.before ]]; then
        previous=$(<"$sess/proxy.before")
        if [[ $previous == null ]]; then
            adb_timeout shell settings delete global http_proxy >/dev/null 2>&1
        else
            previous=${previous//\'/\'\\\'\'}
            adb_timeout shell settings put global http_proxy "'$previous'" >/dev/null 2>&1
        fi
    elif [[ -e $sess/proxy ]]; then
        adb_timeout shell settings put global http_proxy :0 >/dev/null 2>&1
    fi
}

capture_start_abort() {
    local exit_code=$?
    trap - EXIT INT TERM
    if (( exit_code != 0 )); then
        capture_stop_active || echo "error: capture cleanup incomplete; retry './redroid.sh capture stop'" >&2
    fi
    exit "$exit_code"
}

# Record the Android netns identity; transparent mode also needs nft_redir.
capture_prepare_namespace() {
    local sess=$1 netns_pid=$2 mode=$3
    # Keep metadata owned by the caller, not root.
    # shellcheck disable=SC2024
    sudo stat -Lc %i "/proc/$netns_pid/ns/net" >"$sess/netns.id"
    [[ $(<"$sess/netns.id") != "$(sudo stat -Lc %i /proc/1/ns/net)" ]] || \
        die "refusing capture rules in the host network namespace"
    if [[ $mode == transparent && ! -d /sys/module/nft_redir ]]; then
        : >"$sess/module.loaded"
        sudo modprobe nft_redir || die "host kernel lacks nftables redirect support (nft_redir)"
    fi
}

# tcpdump runs inside the container's network namespace so it sees every
# packet (HTTPS, UDP/P2P, DNS, ...); it then drops to the invoking user so
# the pcap is user-owned. fd 9 is closed so the lifecycle lock is not inherited.
capture_start_tcpdump() {
    local sess=$1 netns_pid=$2 user
    user=$(id -un)
    : >"$sess/tcpdump.pid"
    # The log redirect is deliberately made by the invoking user, not by sudo.
    # shellcheck disable=SC2024
    sudo sh -c "$PIDFILE_EXEC" sh "$sess/tcpdump.pid" \
        nsenter -t "$netns_pid" -n \
        tcpdump -i any -U -Z "$user" -w "$sess/full.pcap" 'not tcp port 5555' \
        >"$sess/tcpdump.log" 2>&1 9>&- &
    sleep 2
    proc_is tcpdump "$(cat "$sess/tcpdump.pid" 2>/dev/null)" || \
        die "tcpdump failed to start (see $sess/tcpdump.log)"
}

capture_start_mitm() {
    local sess=$1 mode=$2 netns_pid=$3 gateway previous endpoint
    if [[ $mode == transparent ]]; then
        gateway=127.0.0.1
    else
        gateway=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.Gateway}}{{end}}' "$CONTAINER_NAME")
        [[ -n $gateway ]] || die "cannot resolve the container's Docker gateway"
    fi
    start_mitmproxy "$sess" "$gateway" "$mode" "$netns_pid"
    adb_connect
    install_mitm_ca
    previous=$(adb_shell settings get global http_proxy | tr -d '\r')
    printf '%s\n' "$previous" >"$sess/proxy.before"
    endpoint=$(<"$sess/proxy")
    if [[ $mode == transparent ]]; then
        adb_shell settings put global http_proxy :0
        capture_install_rules "$sess" "${endpoint##*:}"
    else
        note "Pointing Android at the proxy ($endpoint)"
        adb_shell settings put global http_proxy "$endpoint"
        capture_install_rules "$sess"
    fi
}

capture_start() {
    local use_mitm=1 mode=regular sess netns_pid package='' uid=''
    while (( $# )); do
        case $1 in
            --no-mitm) use_mitm=0 ;;
            --transparent) mode=transparent ;;
            --app)
                [[ $# -ge 2 && -z $package ]] || die "--app requires one package"
                package=$2; validate_package "$package"; shift
                ;;
            *) die "usage: $0 capture start [--no-mitm|--transparent] [--app <package>]" ;;
        esac
        shift
    done
    [[ $use_mitm == 1 || $mode != transparent ]] || die "--no-mitm and --transparent cannot be combined"
    [[ -z $package || $mode == transparent ]] || die "--app requires --transparent"
    need tcpdump nsenter timeout
    [[ $use_mitm == 0 ]] || need mitmdump openssl nft lsns
    if [[ $mode == transparent ]]; then
        need setpriv modprobe rmmod
        (( $(id -u) != 0 )) || die "run transparent capture as the calling user, not root"
    fi
    require_running
    capture_active && die "a capture is already running ($(<"$CAPTURE_CURRENT")); run '$0 capture stop'"

    if [[ -n $package ]]; then
        need adb
        adb_connect
        uid=$(app_uid "$package")
    fi
    umask 077
    sess=$(stamped_dir "$CAPTURE_DIR")
    printf '%s\n' "$sess" >"$CAPTURE_CURRENT"
    trap_exit capture_start_abort
    if [[ -n $package ]]; then
        printf '%s\n' "$package" >"$sess/app.package"
        printf '%s\n' "$uid" >"$sess/app.uid"
        note "Proxying $package (UID $uid); pcap still includes all apps"
    fi
    note "Capture session: $sess"

    sudo -v
    netns_pid=$(docker inspect -f '{{.State.Pid}}' "$CONTAINER_NAME")
    [[ $netns_pid =~ ^[1-9][0-9]*$ ]] || die "invalid container PID"
    [[ $use_mitm == 0 ]] || capture_prepare_namespace "$sess" "$netns_pid" "$mode"
    capture_start_tcpdump "$sess" "$netns_pid"
    if [[ $use_mitm == 1 ]]; then
        capture_start_mitm "$sess" "$mode" "$netns_pid"
    else
        note "mitmproxy disabled; capturing raw packets only"
    fi
    trap - EXIT INT TERM
    note "Capturing. Use the app, then run '$0 capture stop'"
}

capture_stop_active() {
    local sess pid
    capture_active || return 0
    sess=$(<"$CAPTURE_CURRENT")
    note "Stopping capture: $sess"

    capture_remove_redirect "$sess" || \
        { echo "error: could not remove capture redirect; keeping capture state for recovery" >&2; return 1; }
    capture_restore_module "$sess" || \
        { echo "error: could not unload capture module; keeping capture state for recovery" >&2; return 1; }
    if ! capture_restore_proxy "$sess"; then
        if container_running; then
            echo "error: could not restore Android proxy; keeping capture state for retry" >&2
            return 1
        fi
        warn "Android is stopped; previous proxy value remains in $sess/proxy.before for manual recovery"
    fi
    pid=$(cat "$sess/mitm.pid" 2>/dev/null || true)
    if proc_is mitmdump "$pid"; then
        kill -TERM "$pid" || return 1
        wait_pid_exit "$pid" || return 1
    fi
    pid=$(cat "$sess/tcpdump.pid" 2>/dev/null || true)
    if proc_is tcpdump "$pid"; then
        sudo kill -INT "$pid" || return 1
        wait_pid_exit "$pid" || return 1
    fi
    rm -f "$sess/tcpdump.pid" "$sess/mitm.pid" "$CAPTURE_CURRENT"

    # Injecting mitmproxy's TLS keys lets Wireshark decrypt the HTTPS legs
    # while non-proxied traffic stays raw.
    if [[ -s $sess/sslkeylog.txt && -s $sess/full.pcap ]] && command -v editcap >/dev/null 2>&1; then
        editcap --inject-secrets "tls,$sess/sslkeylog.txt" \
            "$sess/full.pcap" "$sess/full-decrypted.pcapng" 2>/dev/null || \
            warn "TLS key injection failed; pair full.pcap with sslkeylog.txt manually"
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
        *) die "usage: $0 capture {start [--no-mitm|--transparent]|stop|status}" ;;
    esac
}
