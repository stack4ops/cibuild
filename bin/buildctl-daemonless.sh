#!/bin/sh
# buildctl-daemonless.sh spawns ephemeral buildkitd for executing buildctl.
#
# Usage: buildctl-daemonless.sh build ...
#
# Flags for buildkitd can be specified as $BUILDKITD_FLAGS .
#
# The script is compatible with BusyBox shell.
set -eu

# cibuild patch
ls -lat "$CIBUILD_LIB_PATH/env.sh"

: ${BUILDCTL=buildctl}
: ${BUILDCTL_CONNECT_RETRIES_MAX=10}
: ${BUILDKITD=buildkitd}
: ${BUILDKITD_FLAGS=}
: ${ROOTLESSKIT=rootlesskit}

cleanup() {
    if [ -f "$tmp/pid" ]; then
        pid=$(cat "$tmp/pid")
        kill "$pid" 2>/dev/null || true
    fi

    # dump buildkitd log only at CIBUILD_LOG_LEVEL >= 3 (dump)
    if [ "${CIBUILD_LOG_LEVEL:-0}" -ge 3 ] && [ -f "$tmp/log" ] && [ -s "$tmp/log" ]; then
        printf '\033[35m========== buildkitd log ==========\033[0m\n' >&2
        while IFS= read -r line; do
            printf '\033[35m%s\033[0m\n' "$line" >&2
        done < "$tmp/log"
        printf '\033[35m====================================\033[0m\n' >&2
    fi

    rm -rf "$tmp"
}

# $tmp holds the following files:
# * pid
# * addr
# * log
tmp=$(mktemp -d /tmp/buildctl-daemonless.XXXXXX)
trap "cleanup" EXIT

startBuildkitd() {
    addr=unix://${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/buildkit/buildkitd.sock
    helper=
    if [ -n "${ROOTLESSKIT_STATE_DIR:-}" ]; then
        printf '%s\n' "already inside rootlesskit - never start it again"
        :
    elif [ "$(id -u)" = "0" ]; then
        printf '%s\n' "real root: set default socket"
        addr=unix:///run/buildkit/buildkitd.sock
    else
        printf '%s\n' "use rootlesskit helper"
        helper=$ROOTLESSKIT
    fi
    $helper $BUILDKITD $BUILDKITD_FLAGS --addr=$addr >$tmp/log 2>&1 &
    pid=$!
    echo $pid >$tmp/pid
    echo $addr >$tmp/addr
}

# buildkitd supports NOTIFY_SOCKET but as far as we know, there is no easy way
# to wait for NOTIFY_SOCKET activation using busybox-builtin commands...
waitForBuildkitd() {
    addr=$(cat $tmp/addr)
    try=0
    max=$BUILDCTL_CONNECT_RETRIES_MAX
    until $BUILDCTL --addr=$addr debug workers >/dev/null 2>&1; do
        if [ $try -gt $max ]; then
            echo >&2 "could not connect to $addr after $max trials"
            echo >&2 "========== log =========="
            cat >&2 $tmp/log
            exit 1
        fi
        sleep $(awk "BEGIN{print (100 + $try * 20) * 0.001}")
        try=$(expr $try + 1)
    done
}

startBuildkitd
waitForBuildkitd
$BUILDCTL --addr=$(cat $tmp/addr) "$@"