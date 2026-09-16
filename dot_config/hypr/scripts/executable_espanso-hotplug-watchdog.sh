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

recover_espanso() {
    local now

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

handle_log_line() {
    local line=$1

    [[ "$line" == *"Can't read from device /dev/input/event"* && \
       "$line" == *"removing from epoll"* ]] || return 0

    recover_espanso
}

handle_keyboard_identity() {
    local previous=$1 current=$2

    [[ -n "$previous" && -n "$current" && "$previous" != "$current" ]] || return 0

    recover_espanso
}

current_keyboard_identity() {
    local line='' matched=0 sysfs='' event=''

    while IFS= read -r line; do
        if [[ "$line" == 'N: Name="Keychron Keychron Q6 HE Keyboard"' ]]; then
            matched=1
            sysfs=''
            event=''
            continue
        fi

        if (( matched )); then
            [[ "$line" == 'S: Sysfs='* ]] && sysfs=${line#S: Sysfs=}
            if [[ "$line" == 'H: Handlers='* && "$line" =~ event([0-9]+) ]]; then
                event=${BASH_REMATCH[1]}
            fi
            if [[ -z "$line" ]]; then
                [[ -n "$sysfs" && -n "$event" ]] && printf 'event%s|%s\n' "$event" "$sysfs"
                return 0
            fi
        fi
    done < /proc/bus/input/devices
}

main() {
    local previous='' current=''

    previous=$(current_keyboard_identity)
    while pgrep -x Hyprland >/dev/null; do
        current=$(current_keyboard_identity)
        handle_keyboard_identity "$previous" "$current"
        [[ -n "$current" ]] && previous=$current
        sleep 1
    done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
