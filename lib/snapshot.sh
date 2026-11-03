# shellcheck shell=bash
# `snapshot save|restore`: copy Android data while the container is stopped.

# Trap state is global because Bash unwinds function locals before EXIT on errors.
snapshot_finish() {
    local exit_code=$? recovered=1
    trap - EXIT INT TERM
    set +e
    if [[ -n $SNAPSHOT_WORK && -d $SNAPSHOT_WORK/previous && ! -e $SNAPSHOT_DATA ]]; then
        sudo mv -T -- "$SNAPSHOT_WORK/previous" "$SNAPSHOT_DATA" || recovered=0
    fi
    if [[ $SNAPSHOT_RESTART == 1 && $recovered == 1 ]]; then
        note "Restarting redroid"
        if ! docker start "$CONTAINER_NAME" >/dev/null || ! wait_for_android; then
            echo "error: restart failed; run './redroid.sh stop' to recover the host" >&2
            exit_code=1
        fi
    fi
    if [[ $recovered == 0 || ( $exit_code != 0 && -n $SNAPSHOT_WORK && -d $SNAPSHOT_WORK/previous ) ]]; then
        echo "error: previous Android data retained at $SNAPSHOT_WORK/previous" >&2
        exit_code=1
    elif [[ -n $SNAPSHOT_WORK ]]; then
        sudo rm -rf -- "$SNAPSHOT_WORK" || exit_code=1
    fi
    exit "$exit_code"
}

# Refuse unless the container (if any) mounts SNAPSHOT_DATA and is in a copyable
# state; sets SNAPSHOT_RESTART=1 when it is running and must come back afterwards.
snapshot_check_container() {
    local containers mounted_data status
    # Unlike inspect's "not found" exit code, a listing failure must abort the copy.
    containers=$(docker container ls --all --format '{{.Names}}')
    grep -Fxq -- "$CONTAINER_NAME" <<<"$containers" || return 0
    mounted_data=$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/data"}}{{.Source}}{{end}}{{end}}' "$CONTAINER_NAME")
    [[ -n $mounted_data && $(realpath -e -- "$mounted_data") == "$SNAPSHOT_DATA" ]] || \
        die "container /data does not match REDROID_DATA_DIR"
    status=$(docker inspect -f '{{.State.Status}}' "$CONTAINER_NAME")
    case $status in
        running)
            [[ -r $STATE_FILE ]] || die "running container has no lifecycle state; stop it before continuing"
            SNAPSHOT_RESTART=1
            ;;
        exited|created) ;;
        *) die "container must be running or stopped, not '$status'" ;;
    esac
}

cmd_snapshot() {
    local action=${1:-} name=${2:-} snapshot_path
    SNAPSHOT_WORK=''
    SNAPSHOT_RESTART=0
    [[ $# == 2 && ( $action == save || $action == restore ) ]] || \
        die "usage: $0 snapshot {save|restore} <name>"
    [[ $name =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] || \
        die "snapshot name must be 1-64 letters, digits, dots, underscores or hyphens, starting with a letter or digit"
    need docker adb sudo flock cp mv mktemp realpath
    acquire_lock
    docker info >/dev/null 2>&1 || die "Docker daemon is unavailable"
    [[ -d $REDROID_DATA_DIR ]] || die "Android data directory is missing: $REDROID_DATA_DIR"
    SNAPSHOT_DATA=$(realpath -e -- "$REDROID_DATA_DIR")
    SNAPSHOT_DIR=$(realpath -m -- "$SNAPSHOT_DIR")
    [[ $SNAPSHOT_DATA != / && $SNAPSHOT_DIR != / && $SNAPSHOT_DIR != "$SNAPSHOT_DATA" && \
       $SNAPSHOT_DIR != "$SNAPSHOT_DATA/"* && $SNAPSHOT_DATA != "$SNAPSHOT_DIR/"* ]] || \
        die "snapshot and Android data directories must be separate, non-nested directories"
    [[ $SCRIPT_DIR != "$SNAPSHOT_DATA" && $SCRIPT_DIR != "$SNAPSHOT_DATA/"* ]] || \
        die "Android data directory must not contain the toolbox itself"
    snapshot_path=$SNAPSHOT_DIR/$name
    if [[ $action == save ]]; then
        [[ ! -e $snapshot_path && ! -L $snapshot_path ]] || die "snapshot already exists: $name"
    else
        [[ -d $snapshot_path/data && ! -L $snapshot_path && ! -L $snapshot_path/data ]] || \
            die "snapshot not found or invalid: $name"
    fi
    snapshot_check_container

    umask 077
    sudo -v
    trap_exit snapshot_finish
    capture_stop_active
    if [[ $SNAPSHOT_RESTART == 1 ]]; then
        frida_forget
        note "Stopping Android for snapshot $action"
        docker stop --time 20 "$CONTAINER_NAME" >/dev/null
        [[ $(docker inspect -f '{{.State.Status}}' "$CONTAINER_NAME") == exited ]] || \
            die "container did not stop"
    fi
    if [[ $action == save ]]; then
        mkdir -p -- "$SNAPSHOT_DIR"
        SNAPSHOT_WORK=$(mktemp -d "$SNAPSHOT_DIR/.save-$name.XXXXXX")
        sudo cp -a --reflink=auto --sparse=always -- "$SNAPSHOT_DATA" "$SNAPSHOT_WORK/data"
        mv -T -- "$SNAPSHOT_WORK" "$snapshot_path"
        SNAPSHOT_WORK=''
        note "Snapshot saved: $snapshot_path"
    else
        SNAPSHOT_WORK=$(mktemp -d "${SNAPSHOT_DATA%/*}/.redroid-restore.XXXXXX")
        sudo cp -a --reflink=auto --sparse=always -- "$snapshot_path/data" "$SNAPSHOT_WORK/data"
        sudo mv -T -- "$SNAPSHOT_DATA" "$SNAPSHOT_WORK/previous"
        sudo mv -T -- "$SNAPSHOT_WORK/data" "$SNAPSHOT_DATA"
        note "Snapshot restored: $name"
    fi
    snapshot_finish
}
