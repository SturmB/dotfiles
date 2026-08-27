#!/bin/bash
# Keep waybar alive across the recurring libgdk-3 SIGSEGV — a GTK3/Wayland
# event-dispatch bug (crash on the main thread inside libgdk-3.so.0 while
# handling a Wayland event). See the "Hyprland on CachyOS" vault note.
#
# Launched from hyprland.conf:
#     exec-once = ~/.config/hypr/scripts/waybar-respawn.sh
#
# On first launch this just starts waybar. On every *respawn* after a crash it
# also re-runs restart-tray-apps.sh, because the five tray apps that only
# register at startup (arch-update, Polychromatic, jetbrains-toolbox,
# pia-client, StreamController) lose their tray icons when waybar — which owns the
# StatusNotifierWatcher — dies. (restart-tray-apps.sh waits for the watcher to
# be back on the bus before relaunching them.)
#
# Manual restart hotkey SUPER+Shift+B just runs `killall waybar`; this loop
# brings it straight back. Do NOT spawn waybar from the hotkey too, or you'll
# race a double instance against this loop.

set -u

first=1
while true; do
    waybar &
    wpid=$!

    if [ "$first" -eq 0 ]; then
        ~/.config/hypr/scripts/restart-tray-apps.sh &
    fi
    first=0

    wait "$wpid"
    # Hyprland doesn't kill exec-once children on logout, so this loop would
    # otherwise orphan to PID 1 and keep respawning waybar — a second one then
    # appears at next login (double bar). If the compositor is gone, stop.
    pgrep -x Hyprland >/dev/null || break
    sleep 1
done
