#!/bin/bash
# Launch the PIA VPN client and dismiss its startup dashboard popup so only the
# tray icon remains visible. PIA auto-hides the popup whenever another window
# takes focus, so we simply move focus away once the dashboard has mapped —
# this preserves the window for normal tray-click reuse (unlike WM_DELETE_WINDOW,
# which destroys it).

# Wait for waybar's StatusNotifierWatcher before launching. pia-client (Qt)
# registers its SNI tray icon once at startup; if the watcher isn't on the bus
# yet, PIA misses the window and the tray icon never appears. Same race that
# 1Password hits — see hyprland.conf line 88. Cap the wait at 10s so a broken
# waybar doesn't hang autostart forever.
for _ in $(seq 1 100); do
    busctl --user status org.kde.StatusNotifierWatcher &>/dev/null && break
    sleep 0.1
done

env XDG_SESSION_TYPE=X11 /opt/piavpn/bin/pia-client &

# Wait up to 10s for the dashboard to appear
for _ in $(seq 1 100); do
    PIA_ADDR=$(hyprctl clients -j 2>/dev/null \
        | jq -r '.[] | select(.class=="privateinternetaccess") | .address' \
        | head -1)
    [ -n "$PIA_ADDR" ] && [ "$PIA_ADDR" != "null" ] && break
    sleep 0.1
done

[ -z "$PIA_ADDR" ] && exit 0
[ "$PIA_ADDR" = "null" ] && exit 0

# Brief pause so PIA finishes placing the window before we move focus
sleep 0.2

# Stash PIA on a hidden special workspace so it's out of sight but still alive
# for tray-click reuse. Previous approach (focus another window to trigger PIA's
# hide-on-focus-out) broke with follow_mouse=2 / Hyprland 0.55 focus changes.
hyprctl dispatch movetoworkspacesilent "special:piahide,address:$PIA_ADDR"
