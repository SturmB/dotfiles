#!/bin/bash
# Restart tray apps that don't re-register with the StatusNotifierWatcher after
# waybar restarts or crashes. Steam, udiskie, dropbox, vesktop, 1password, and
# teams-for-linux re-register themselves on watcher reappearance; the four below
# only register at process startup, so they need an explicit kick.

set -u

# Use exact-PID kills, never pkill -f patterns — those match this script's own
# command line and self-kill the shell.
declare -A WANT=(
    [arch-update-tray]='python3 /usr/share/arch-update/lib/tray.py'
    [jetbrains-toolbox]='/home/kerban/.local/share/JetBrains/Toolbox/bin/jetbrains-toolbox'
    [pia-client]='/opt/piavpn/bin/pia-client'
    [streamcontroller]='StreamController'
)

for key in "${!WANT[@]}"; do
    case "$key" in
        arch-update-tray)
            pid=$(pgrep -fx "$(printf '%s' "${WANT[$key]}")" | head -1)
            [ -n "$pid" ] && kill "$pid"
            # also kill the bash wrapper
            wrapper=$(pgrep -fx "/bin/bash /usr/bin/arch-update --tray" | head -1)
            [ -n "$wrapper" ] && kill "$wrapper"
            ;;
        jetbrains-toolbox)
            pid=$(pgrep -f "^${WANT[$key]}" | head -1)
            [ -n "$pid" ] && kill "$pid"
            ;;
        pia-client)
            pid=$(pgrep -fx "${WANT[$key]}" | head -1)
            [ -n "$pid" ] && kill "$pid"
            ;;
        streamcontroller)
            pid=$(pgrep -x StreamController | head -1)
            [ -n "$pid" ] && kill "$pid"
            ;;
    esac
done

# Give them a moment to exit and release D-Bus names
sleep 2

# Wait for the StatusNotifierWatcher to be available (waybar may still be
# starting if the user just restarted it).
for _ in $(seq 1 100); do
    busctl --user status org.kde.StatusNotifierWatcher &>/dev/null && break
    sleep 0.1
done

setsid arch-update --tray >/dev/null 2>&1 < /dev/null & disown
setsid env GDK_SCALE=1 /home/kerban/.local/share/JetBrains/Toolbox/bin/jetbrains-toolbox --minimize >/dev/null 2>&1 < /dev/null & disown
setsid /home/kerban/.config/hypr/scripts/pia-launch.sh >/dev/null 2>&1 < /dev/null & disown
setsid flatpak run com.core447.StreamController -b >/dev/null 2>&1 < /dev/null & disown

notify-send -t 3000 "Tray apps restarted" "arch-update, jetbrains-toolbox, pia-client, StreamController" 2>/dev/null || true
