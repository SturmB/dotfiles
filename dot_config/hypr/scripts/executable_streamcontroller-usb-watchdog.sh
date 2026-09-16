#!/usr/bin/env bash
# Recover StreamController only after its exact Stream Deck XL hot-plug log entry.
# The Dell U2723QE KVM re-enumerates the deck on a Titan return, which can crash
# StreamController's GTK4 page reload. The application emits the full USB device
# identity immediately before that crash; tailing that log is more reliable than
# a user-session udev stream. The service remains the sole app launcher.

set -u -o pipefail

readonly streamcontroller_app=com.core447.StreamController
readonly streamcontroller_unit=streamcontroller.service
readonly streamdeck_vendor=0fd9
readonly streamdeck_product=006c
readonly streamdeck_serial=CL46I1A01110
readonly streamcontroller_log="${SC_WATCHDOG_LOG_FILE:-$HOME/.var/app/${streamcontroller_app}/data/logs/logs.log}"
readonly reconnect_delay_seconds=3
readonly lock_file="${SC_WATCHDOG_LOCK_FILE:-${XDG_RUNTIME_DIR:-/tmp}/streamcontroller-usb-watchdog.lock}"

streamcontroller_instance_exists() {
    flatpak ps --columns=application 2>/dev/null | grep -Fxq "$streamcontroller_app"
}

recover_if_failed() {
    local lock_fd

    # Coalesce the Dell hub, camera, Ethernet, and Stream Deck USB events into
    # one recovery attempt; never race an already-running Flatpak instance.
    exec {lock_fd}>"$lock_file"
    flock -n "$lock_fd" || {
        exec {lock_fd}>&-
        return 0
    }

    if ! systemctl --user is-active --quiet graphical-session.target || \
       ! systemctl --user is-failed --quiet "$streamcontroller_unit" || \
       streamcontroller_instance_exists; then
        flock -u "$lock_fd"
        exec {lock_fd}>&-
        return 0
    fi

    sleep "$reconnect_delay_seconds"

    if systemctl --user is-active --quiet graphical-session.target && \
       systemctl --user is-failed --quiet "$streamcontroller_unit" && \
       ! streamcontroller_instance_exists; then
        systemctl --user start "$streamcontroller_unit"
    fi

    flock -u "$lock_fd"
    exec {lock_fd}>&-
}

handle_usb_event() {
    local action=$1 devtype=$2 vendor=${3,,} product=${4,,} serial=$5

    [[ "$action" == add && "$devtype" == usb_device && \
       "$vendor" == "$streamdeck_vendor" && "$product" == "$streamdeck_product" && \
       "$serial" == "$streamdeck_serial" ]] || return 0

    recover_if_failed
}

handle_streamcontroller_log_line() {
    local line=$1

    [[ "$line" == *"Device "* && "$line" == *" connected"* && \
       "$line" == *"'ID_MODEL_ID': '006c'"* && \
       "$line" == *"'ID_VENDOR_ID': '0fd9'"* && \
       "$line" == *"'ID_SERIAL': 'Elgato_Stream_Deck_XL_${streamdeck_serial}'"* ]] || return 0

    recover_if_failed
}

main() {
    local line=''

    # Start at EOF so a historical hot-plug cannot revive an old failed unit.
    tail -n0 -F "$streamcontroller_log" 2>/dev/null | while IFS= read -r line; do
        systemctl --user is-active --quiet graphical-session.target || break
        handle_streamcontroller_log_line "$line"
    done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
