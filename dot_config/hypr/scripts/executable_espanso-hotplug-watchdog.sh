#!/usr/bin/env bash
# Restart Espanso after a KVM-induced EVDEV disconnect. Espanso 2.4's worker
# removes disconnected /dev/input/event* devices from epoll but does not reopen
# them when the Comet Pro returns the Keychron/Razer USB devices to Titan.
#
# Hyprland owns this watchdog. It exits when Hyprland exits, so it cannot keep
# an Espanso instance alive across a lingering user-manager session.

set -u -o pipefail

readonly log_file="${ESPANSO_LOG_FILE:-$HOME/.cache/espanso/espanso.log}"
readonly reconnect_delay_seconds=3
readonly restart_cooldown_seconds=10
last_restart_at=0

handle_log_line() {
    local line=$1
    local now

    [[ "$line" == *"Can't read from device /dev/input/event"* && \
       "$line" == *"removing from epoll"* ]] || return 0

    now=$(date +%s)
    (( now - last_restart_at >= restart_cooldown_seconds )) || return 0
    last_restart_at=$now

    # Let the KVM finish USB enumeration before creating Espanso's fresh EVDEV
    # subscriptions. Do not recover after the graphical session has ended.
    sleep "$reconnect_delay_seconds"
    pgrep -x Hyprland >/dev/null || return 0

    espanso service stop >/dev/null 2>&1 || true
    espanso launcher >/dev/null 2>&1 &
}

main() {
    tail -n0 -F "$log_file" 2>/dev/null | while IFS= read -r line; do
        pgrep -x Hyprland >/dev/null || break
        handle_log_line "$line"
    done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
