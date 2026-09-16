#!/usr/bin/env bash
# Behavioral tests for the Hyprland-scoped Espanso KVM hot-plug watchdog.
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
watchdog="$script_dir/../dot_config/hypr/scripts/executable_espanso-hotplug-watchdog.sh"

workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT
calls="$workdir/calls"
: >"$calls"

# Test doubles: keep the test side-effect-free while recording recovery actions.
espanso() {
    printf '%s\n' "$*" >>"$calls"
}
sleep() {
    printf 'sleep %s\n' "$*" >>"$calls"
}
pgrep() {
    return 0
}

# shellcheck source=/dev/null
source "$watchdog"

assert_calls() {
    local expected=$1
    local actual
    actual=$(<"$calls")
    if [[ "$actual" != "$expected" ]]; then
        printf 'expected calls:\n%s\nactual calls:\n%s\n' "$expected" "$actual" >&2
        return 1
    fi
}

# A KVM-triggered EVDEV removal must wait for USB enumeration, then replace the
# unmanaged Espanso launcher exactly once.
handle_log_line '12:00:00 [worker(1)] [WARN] Can'"'"'t read from device /dev/input/event3, this error usually means the device has been disconnected, removing from epoll.'
wait
assert_calls $'sleep 3\nservice stop\nlauncher'

# A KVM switch drops several interfaces in one burst. Coalesce those lines into
# one recovery instead of repeatedly tearing down the freshly restarted worker.
: >"$calls"
last_restart_at=0
handle_log_line '12:01:00 [worker(1)] [WARN] Can'"'"'t read from device /dev/input/event3, this error usually means the device has been disconnected, removing from epoll.'
wait
handle_log_line '12:01:00 [worker(1)] [WARN] Can'"'"'t read from device /dev/input/event4, this error usually means the device has been disconnected, removing from epoll.'
wait
assert_calls $'sleep 3\nservice stop\nlauncher'

# KVM reconnects may reuse the same /dev/input/eventN. Detect the new sysfs HID
# instance instead, and recover when the Keychron identity changes.
: >"$calls"
last_restart_at=0
handle_keyboard_identity 'event3|0003:3434:0B60.00A1' 'event3|0003:3434:0B60.00B9'
wait
assert_calls $'sleep 3\nservice stop\nlauncher'

# Ordinary Espanso diagnostics must not restart it.
: >"$calls"
handle_log_line '12:00:01 [worker(1)] [WARN] unable to determine keyboard layout automatically'
assert_calls ''

printf 'espanso-hotplug-watchdog tests: PASS\n'
