#!/usr/bin/env bash
# Behavioral tests for the Hyprland-scoped StreamController USB watchdog.
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
watchdog="$script_dir/../dot_config/hypr/scripts/executable_streamcontroller-usb-watchdog.sh"

workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT
calls="$workdir/calls"
: >"$calls"
export SC_WATCHDOG_LOCK_FILE="$workdir/watchdog.lock"
failed=1
flatpak_instance=0

systemctl() {
    if [[ "$*" == '--user is-active --quiet graphical-session.target' ]]; then
        return 0
    fi
    if [[ "$*" == '--user is-failed --quiet streamcontroller.service' ]]; then
        (( failed == 1 ))
        return
    fi
    printf 'systemctl %s\n' "$*" >>"$calls"
}
flatpak() {
    if [[ "$*" == 'ps --columns=application' && $flatpak_instance -eq 1 ]]; then
        printf 'com.core447.StreamController\n'
    fi
}
sleep() {
    printf 'sleep %s\n' "$*" >>"$calls"
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

# The exact Stream Deck XL USB add after a KVM switch recovers a failed service.
handle_usb_event add usb_device 0fd9 006c CL46I1A01110
assert_calls $'sleep 3\nsystemctl --user start streamcontroller.service'

# Other USB devices must never trigger a StreamController launch.
: >"$calls"
handle_usb_event add usb_device 046d 0893 9D9F86E5
assert_calls ''

# A healthy StreamController instance is never restarted merely because the deck
# re-enumerates.
: >"$calls"
failed=0
handle_usb_event add usb_device 0fd9 006c CL46I1A01110
assert_calls ''

# A lingering Flatpak instance is likewise never raced with another launch.
: >"$calls"
failed=1
flatpak_instance=1
handle_usb_event add usb_device 0fd9 006c CL46I1A01110
assert_calls ''

printf 'streamcontroller-usb-watchdog tests: PASS\n'
