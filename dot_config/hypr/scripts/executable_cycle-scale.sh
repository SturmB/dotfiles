#!/bin/bash
# Cycle through scaling options for the focused monitor
# SUPER+/ binding

# Preserve the monitor's current position — using `auto` re-runs Hyprland's
# auto-layout and can swap monitor sides on multi-monitor setups with
# explicit positions in hyprland.conf.

HYPRCONF="$HOME/.config/hypr/hyprland.conf"

MONITOR=$(hyprctl activeworkspace -j | jq -r '.monitor')
read -r CURRENT POS_X POS_Y < <(hyprctl monitors -j | jq -r --arg m "$MONITOR" '.[] | select(.name == $m) | "\(.scale) \(.x) \(.y)"')

# This monitor's configured default scale = last comma-field of its
# `monitor = NAME, ...` line in hyprland.conf (comment stripped).
DEFAULT=$(grep -E "^[[:space:]]*monitor[[:space:]]*=[[:space:]]*$MONITOR," "$HYPRCONF" \
    | head -1 | sed 's/#.*//' | awk -F',' '{gsub(/[[:space:]]/,"",$NF); print $NF}')
DEFAULT=${DEFAULT:-1.0}

# Cycle = a common set of scales plus this monitor's configured default,
# deduped and sorted ascending. This guarantees the cycle always passes
# back through the default (which Hyprland reports rounded, e.g. 1.666667 -> 1.67).
EXTRA=(1.0 1.25 1.5 2.0)
mapfile -t SCALES < <(printf '%s\n' "${EXTRA[@]}" "$DEFAULT" | sort -g -u)

# Find current scale in list (tolerant — reported scale is rounded to 2dp and
# won't equal a value like 1.666667 exactly) and pick the next entry.
# Fall back to the configured default if nothing matches.
NEXT="$DEFAULT"
for i in "${!SCALES[@]}"; do
    if awk -v a="${SCALES[$i]}" -v b="$CURRENT" 'BEGIN{d=a-b; if(d<0)d=-d; exit !(d<0.01)}'; then
        NEXT=${SCALES[$(( (i + 1) % ${#SCALES[@]} ))]}
        break
    fi
done

hyprctl keyword monitor "$MONITOR,preferred,${POS_X}x${POS_Y},$NEXT"
notify-send "Monitor Scale" "$MONITOR → ${NEXT}x" -t 2000
