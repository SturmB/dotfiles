#!/bin/bash
# Cycle through scaling options for the focused monitor
# SUPER+/ binding

# Preserve the monitor's current position — using `auto` re-runs Hyprland's
# auto-layout and can swap monitor sides on multi-monitor setups with
# explicit positions in hyprland.lua.

HYPRCONF="$HOME/.config/hypr/hyprland.lua"

MONITOR=$(hyprctl activeworkspace -j | jq -r '.monitor')
read -r CURRENT POS_X POS_Y < <(hyprctl monitors -j | jq -r --arg m "$MONITOR" '.[] | select(.name == $m) | "\(.scale) \(.x) \(.y)"')

# This monitor's configured default scale = the `scale = N` field of its
# `hl.monitor({ output = "NAME", ... })` line in hyprland.lua.
DEFAULT=$(grep -E "hl\.monitor\(\{.*output *= *\"$MONITOR\"" "$HYPRCONF" \
    | head -1 | sed -E 's/.*scale *= *([0-9.]+).*/\1/')
if [[ ! $DEFAULT =~ ^[0-9]+\.?[0-9]*$ ]]; then
    notify-send "Monitor Scale" "Couldn't read the default scale for $MONITOR from ${HYPRCONF##*/}" -t 4000
    exit 1
fi

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

# Lua config syntax (Hyprland 0.55+). `hyprctl keyword` is rejected outright:
# "keyword can't work with non-legacy parsers. Use eval."
hyprctl eval "hl.monitor({ output = '$MONITOR', mode = 'preferred', position = '${POS_X}x${POS_Y}', scale = $NEXT })"
notify-send "Monitor Scale" "$MONITOR → ${NEXT}x" -t 2000
