# shellcheck shell=bash
# `reset --yes`: replace Android data using snapshot staging and recovery.

cmd_reset() {
    [[ $# == 1 && $1 == --yes ]] || \
        die "usage: $0 reset --yes (erases all Android apps, accounts, settings and files)"
    snapshot_run reset
}
