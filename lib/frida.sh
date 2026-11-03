# shellcheck shell=bash
# `frida`: pinned frida-server as root in the guest, forwarded to host loopback.

load_frida_inputs() {
    local name
    # shellcheck disable=SC1090
    source "$INPUTS_FILE"
    for name in FRIDA_VERSION FRIDA_TOOLS_VERSION FRIDA_SERVER_SHA256; do
        [[ -n ${!name:-} ]] || die "missing '$name' in $INPUTS_FILE"
    done
}

frida_running() {
    [[ -n $(adb_shell su 0 pidof frida-server 2>/dev/null | tr -d '\r') ]]
}

frida_require_running() {
    need adb
    adb_connect
    frida_running || die "frida-server is not running; run '$0 frida start'"
}

# Drop the host-side adb forward; harmless when it was never set up.
frida_forget() {
    adb_timeout forward --remove "tcp:$FRIDA_PORT" >/dev/null 2>&1 || true
}

# Run a Frida CLI tool against the guest server. A host install is used when its
# version matches the pinned server; otherwise the pinned release runs through uvx.
frida_host() {
    local tool=$1
    shift
    load_frida_inputs
    if command -v frida >/dev/null 2>&1 && [[ $(frida --version) == "$FRIDA_VERSION" ]]; then
        "$tool" -H "127.0.0.1:$FRIDA_PORT" "$@"
    else
        need uvx
        uvx --from "frida-tools==$FRIDA_TOOLS_VERSION" --with "frida==$FRIDA_VERSION" \
            "$tool" -H "127.0.0.1:$FRIDA_PORT" "$@"
    fi
}

# Download, verify and unpack the pinned frida-server once into the cache.
frida_fetch_server() {
    local archive=$FRIDA_DIR/frida-server-$FRIDA_VERSION-android-x86_64.xz
    FRIDA_SERVER_BIN=$FRIDA_DIR/frida-server-$FRIDA_VERSION
    [[ ! -x $FRIDA_SERVER_BIN ]] || return 0
    mkdir -p "$FRIDA_DIR"
    if [[ ! -f $archive ]]; then
        note "Downloading frida-server $FRIDA_VERSION"
        curl -fsSL -o "$archive" \
            "https://github.com/frida/frida/releases/download/$FRIDA_VERSION/frida-server-$FRIDA_VERSION-android-x86_64.xz"
    fi
    echo "$FRIDA_SERVER_SHA256  $archive" | sha256sum -c --quiet - || \
        { rm -f "$archive"; die "frida-server checksum mismatch"; }
    xz -dc "$archive" >"$FRIDA_SERVER_BIN.tmp"
    chmod 755 "$FRIDA_SERVER_BIN.tmp"
    mv "$FRIDA_SERVER_BIN.tmp" "$FRIDA_SERVER_BIN"
}

frida_start() {
    local attempts=0
    need curl xz sha256sum
    require_running
    load_frida_inputs
    frida_fetch_server

    adb_connect
    if frida_running; then
        note "frida-server is already running"
    else
        note "Starting frida-server as root in the guest"
        adb_dev push "$FRIDA_SERVER_BIN" "$FRIDA_GUEST_BIN" >/dev/null
        adb_shell su 0 sh -c "'chmod 755 $FRIDA_GUEST_BIN; setsid $FRIDA_GUEST_BIN -l 127.0.0.1:$FRIDA_PORT </dev/null >/dev/null 2>&1 &'"
        until frida_running; do
            (( ++attempts < 10 )) || die "frida-server did not start in the guest"
            sleep 1
        done
    fi
    adb_dev forward "tcp:$FRIDA_PORT" "tcp:$FRIDA_PORT" >/dev/null
    note "frida-server ready on 127.0.0.1:$FRIDA_PORT (try: $0 frida exec frida-ps -a)"
}

frida_stop() {
    frida_forget
    container_running || return 0
    adb_connect
    adb_shell su 0 sh -c "'kill \$(pidof frida-server)'" >/dev/null 2>&1 || true
    note "frida-server stopped"
}

cmd_frida() {
    local action=${1:-}
    [[ $# -eq 0 ]] || shift
    case $action in
        start) acquire_lock; need adb; frida_start ;;
        stop) acquire_lock; need adb; frida_stop ;;
        unpin)
            [[ -n ${1:-} ]] || die "usage: $0 frida unpin <package>"
            frida_require_running
            # The hooks live only while this client stays attached; exit the REPL to detach.
            frida_host frida -f "$1" -l "$SCRIPT_DIR/frida/unpin.js"
            ;;
        exec)
            [[ $# -ge 1 ]] || die "usage: $0 frida exec <frida|frida-ps|frida-trace|...> [args]"
            [[ $1 == frida || $1 == frida-* ]] || die "'$1' is not a Frida tool"
            frida_require_running
            frida_host "$@"
            ;;
        *) die "usage: $0 frida {start|stop|unpin <package>|exec <tool> [args]}" ;;
    esac
}
