#!/bin/bash
# Keep SwayOSD alive if its GTK4/Wayland frontend crashes. The server is the
# target of Hyprland's XF86Audio* bindings; without it, swayosd-client exits
# with org.freedesktop.DBus.Error.ServiceUnknown and the volume knob does
# nothing.
#
# Launched from hyprland.conf:
#     exec-once = ~/.config/hypr/scripts/swayosd-respawn.sh

set -u

while true; do
    /usr/bin/swayosd-server &
    spid=$!
    wait "$spid"
    status=$?

    # Hyprland does not necessarily kill exec-once children on logout. Do not
    # orphan this loop and respawn SwayOSD against a dead Wayland session.
    pgrep -x Hyprland >/dev/null || break

    logger -t swayosd-respawn -- \
        "swayosd-server exited with status $status; restarting in 2 seconds"
    sleep 2
done
