#!/bin/bash
# Launch the PIA VPN client and dismiss its startup dashboard so only the tray
# icon remains visible. The dashboard is an XWayland window; unmapping it keeps
# PIA's own "Show Window" action able to remap it on the current workspace.
# Do not stash the mapped window on a hidden workspace: PIA only raises the
# existing window and Hyprland will leave it marooned there.

# Wait for Waybar's StatusNotifierWatcher before launching. pia-client (Qt)
# registers its SNI tray icon once at startup; if the watcher isn't on the bus
# yet, PIA misses the window and never retries. Cap the wait at 10s so a broken
# Waybar doesn't hang autostart forever.
for _ in $(seq 1 100); do
    busctl --user status org.kde.StatusNotifierWatcher &>/dev/null && break
    sleep 0.1
done

env XDG_SESSION_TYPE=X11 /opt/piavpn/bin/pia-client &
PIA_PID=$!

# Wait up to 10s for this client's visible XWayland dashboard.
PIA_XID=
for _ in $(seq 1 100); do
    PIA_XID=$(xdotool search --onlyvisible --pid "$PIA_PID" \
        --class '^privateinternetaccess$' 2>/dev/null | head -1)
    [ -n "$PIA_XID" ] && break
    sleep 0.1
done

[ -z "$PIA_XID" ] && exit 0

# Let PIA finish initial placement, then hide the dashboard without destroying
# it. A later tray "Show Window" remaps this same window on the active workspace.
sleep 0.2
xdotool windowunmap "$PIA_XID"
