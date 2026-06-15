#!/bin/bash
# Toggle screen recording — press once to start, again to stop
# Uses gpu-screen-recorder (NVIDIA-compatible) instead of wf-recorder

if pgrep -f gpu-screen-recorder > /dev/null; then
    pkill -SIGINT -f gpu-screen-recorder
    notify-send "Recording stopped" "Saved to ~/Videos/Screencasts/"
    exit 0
fi

mkdir -p ~/Videos/Screencasts
FILENAME=~/Videos/Screencasts/Screencast_$(date +'%Y%m%d_%H%M%S').mp4

notify-send "Recording started" "Press Alt+Print to stop"
gpu-screen-recorder -w DP-1 -f 60 -a default_output -o "$FILENAME"
