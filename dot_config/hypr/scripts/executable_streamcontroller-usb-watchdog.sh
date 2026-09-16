#!/usr/bin/env bash
# Recover StreamController only after the exact Stream Deck XL reappears on USB.
# The Dell U2723QE KVM re-enumerates the deck on a Titan return, which can crash
# StreamController's GTK4 page reload. The service itself remains the sole app
# launcher; this watcher starts it only after that crash has left it failed.

set -u -o pipefail

readonly streamcontroller_app=com.core447.StreamController
readonly streamcontroller_unit=streamcontroller.service
readonly streamdeck_vendor=0fd9
readonly streamdeck_product=006c
readonly streamdeck_serial=CL46I1A01110
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

main() {
    local action='' devtype='' vendor='' product='' serial='' line=''

    coproc UDEV_MONITOR { stdbuf -oL udevadm monitor --udev --property --subsystem-match=usb; }

    while systemctl --user is-active --quiet graphical-session.target; do
        if ! IFS= read -r -t 1 line <&"${UDEV_MONITOR[0]}"; then
            continue
        fi

        if [[ -z "$line" ]]; then
            handle_usb_event "$action" "$devtype" "$vendor" "$product" "$serial"
            action=''; devtype=''; vendor=''; product=''; serial=''
            continue
        fi

        case "$line" in
            ACTION=*)          action=${line#ACTION=} ;;
            DEVTYPE=*)         devtype=${line#DEVTYPE=} ;;
            ID_VENDOR_ID=*)    vendor=${line#ID_VENDOR_ID=} ;;
            ID_MODEL_ID=*)     product=${line#ID_MODEL_ID=} ;;
            ID_SERIAL_SHORT=*) serial=${line#ID_SERIAL_SHORT=} ;;
        esac
    done

    kill "$UDEV_MONITOR_PID" 2>/dev/null || true
    wait "$UDEV_MONITOR_PID" 2>/dev/null || true
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
