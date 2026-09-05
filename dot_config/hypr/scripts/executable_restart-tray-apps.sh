#!/bin/bash
# Restart tray apps that do not re-register with the StatusNotifierWatcher after
# the watcher or Waybar restarts. Steam, udiskie, Dropbox, Vesktop, 1Password,
# and teams-for-linux re-register themselves; the five recovery targets below
# need an explicit restart.

set -u

# Resolve candidates first and kill only their exact PIDs. Never use pkill -f:
# its pattern can match the cleanup shell's own command line and kill the script.
declare -A WANT=(
    [arch-update-tray]='/usr/lib/arch-update/arch-update-tray'
    [jetbrains-toolbox]='/usr/bin/jetbrains-toolbox'
    [pia-client]='/opt/piavpn/bin/pia-client'
    [polychromatic-tray-applet]='/usr/bin/polychromatic-tray-applet'
)
declare -a stopped_pids=()
declare -a pids=()

for key in "${!WANT[@]}"; do
    pids=()
    case "$key" in
        arch-update-tray)
            mapfile -t pids < <(pgrep -fx "${WANT[$key]}" 2>/dev/null || true)
            ;;
        jetbrains-toolbox)
            mapfile -t pids < <(pgrep -f "^${WANT[$key]}([[:space:]]|$)" 2>/dev/null || true)
            ;;
        pia-client)
            mapfile -t pids < <(pgrep -fx "${WANT[$key]}" 2>/dev/null || true)
            ;;
        polychromatic-tray-applet)
            mapfile -t pids < <(pgrep -f '^(/usr/bin/)?polychromatic-tray-applet$' 2>/dev/null || true)
            ;;
    esac

    for pid in "${pids[@]}"; do
        if kill "$pid" 2>/dev/null; then
            stopped_pids+=("$pid")
        fi
    done
done

# Do not let a replacement fold into a still-running primary instance. Wait up
# to ten seconds for every process we signalled and for Toolbox's D-Bus name.
for pid in "${stopped_pids[@]}"; do
    for _ in $(seq 1 100); do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.1
    done
    if kill -0 "$pid" 2>/dev/null; then
        notify-send -u critical -t 5000 "Tray recovery stopped" "PID $pid did not exit; no tray apps were relaunched." 2>/dev/null || true
        exit 1
    fi
done

for _ in $(seq 1 100); do
    busctl --user status com.jetbrains.toolbox &>/dev/null || break
    sleep 0.1
done
if busctl --user status com.jetbrains.toolbox &>/dev/null; then
    notify-send -u critical -t 5000 "Tray recovery stopped" "JetBrains Toolbox did not release its D-Bus name." 2>/dev/null || true
    exit 1
fi

# Fail closed if no watcher appears; launching these apps without one recreates
# the missing-icon condition they cannot repair themselves.
watcher_ready=0
for _ in $(seq 1 100); do
    if busctl --user status org.kde.StatusNotifierWatcher &>/dev/null; then
        watcher_ready=1
        break
    fi
    sleep 0.1
done
if [ "$watcher_ready" -ne 1 ]; then
    notify-send -u critical -t 5000 "Tray recovery stopped" "org.kde.StatusNotifierWatcher did not become available." 2>/dev/null || true
    exit 1
fi

setsid arch-update --tray >/dev/null 2>&1 < /dev/null & disown
setsid polychromatic-helper --autostart >/dev/null 2>&1 < /dev/null & disown
setsid /usr/bin/jetbrains-toolbox --jvm-args=/home/kerban/.config/JetBrains/Toolbox/toolbox.vmoptions --minimize >/dev/null 2>&1 < /dev/null & disown
setsid /home/kerban/.config/hypr/scripts/pia-launch.sh >/dev/null 2>&1 < /dev/null & disown

# StreamController is managed by its systemd unit. The unit's ExecStartPre uses
# `flatpak kill`, avoiding the truncated-comm bug from the retired pgrep branch.
systemctl --user restart streamcontroller.service

notify-send -t 3000 "Tray apps restarted" "arch-update, Polychromatic, JetBrains Toolbox, PIA, StreamController" 2>/dev/null || true
