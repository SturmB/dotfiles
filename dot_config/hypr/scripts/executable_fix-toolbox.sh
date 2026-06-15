#!/usr/bin/env bash
# Watches for JetBrains Toolbox window open events and repositions it,
# because the XWayland app overrides WM placement with its own size hints.

socat -U - UNIX-CONNECT:"$XDG_RUNTIME_DIR/hypr/$HYPRLAND_INSTANCE_SIGNATURE/.socket2.sock" |
  while read -r line; do
    # Format: openwindow>>WINDOWADDRESS,WORKSPACENAME,WINDOWCLASS,WINDOWTITLE
    event="${line%%>>*}"
    data="${line#*>>}"
    if [[ "$event" == "openwindow" && "$data" == *"jetbrains-toolbox"* ]]; then
      addr="0x${data%%,*}"
      sleep 0.3
      coords=$(
        hyprctl clients -j | python3 -c "
import json, sys
for c in json.load(sys.stdin):
    if c['address'] == '$addr':
        print(c['at'][0] + c['size'][0]//2, c['at'][1] + c['size'][1]//2)
        break
"
      )
      if [[ -n "$coords" ]]; then
        cx=${coords% *}; cy=${coords#* }
        # First warp warps into the window so focus_follows_mouse keeps
        # focus on the Toolbox while we resize + center it.
        hyprctl --batch "dispatch movecursor $cx $cy ; dispatch focuswindow address:$addr ; dispatch resizeactive exact 480 700 ; dispatch centerwindow" > /dev/null
        # Second warp lands the cursor on the widget's final position so
        # the user's pointer follows the Toolbox to its new home.
        final=$(
          hyprctl clients -j | python3 -c "
import json, sys
for c in json.load(sys.stdin):
    if c['address'] == '$addr':
        print(c['at'][0] + c['size'][0]//2, c['at'][1] + c['size'][1]//2)
        break
"
        )
        if [[ -n "$final" ]]; then
          hyprctl dispatch movecursor ${final% *} ${final#* } > /dev/null
        fi
      fi
    fi
  done
