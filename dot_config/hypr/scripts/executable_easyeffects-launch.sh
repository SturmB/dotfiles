#!/usr/bin/env bash
# Launch EasyEffects in service mode, but first wait for the
# StatusNotifierWatcher (claimed by Waybar's tray module) to appear on the bus.
#
# EasyEffects v8 registers its tray icon (StatusNotifierItem) once, at startup.
# At login the autostart races Waybar; if the watcher isn't on the bus yet the
# registration silently fails and the tray icon never appears — the same race
# already handled for 1Password, PIA, and Vesktop. Waiting first makes the
# native EasyEffects tray icon show up reliably.
#
# Bounded wait (~10s) then launch regardless, so audio processing always starts
# even if the watcher never appears (e.g. Waybar disabled).

for _ in $(seq 1 100); do
    busctl --user status org.kde.StatusNotifierWatcher &>/dev/null && break
    sleep 0.1
done

exec easyeffects --gapplication-service
