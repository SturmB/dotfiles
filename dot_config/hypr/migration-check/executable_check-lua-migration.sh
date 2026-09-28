#!/usr/bin/env bash
# Verification for the hyprland.conf -> hyprland.lua migration.
# A/B-diffs the live instance against snapshots taken while the old .conf was
# still running, so it compares against what actually worked.
S="$(cd "$(dirname "$0")" && pwd)"
fail=0
ok()  { printf '  \033[32mok\033[0m   %s\n' "$1"; }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }

for f in binds-before.txt monitors-before.json wsrules-before.json options-before.txt; do
    [ -f "$S/$f" ] || { echo "missing baseline $S/$f — cannot A/B"; exit 2; }
done

echo "== 1. running on the Lua config"
# `hyprctl eval` is refused outright by the legacy parser, so this doubles as the
# "am I on lua yet?" probe.
if hyprctl eval 'return 1' 2>&1 | grep -qx ok; then ok "lua config manager active"
else bad "still on .conf — hyprland.lua was not loaded"; exit 1; fi

echo "== 2. binds: same key combos and flags as the .conf produced"
# Handlers are excluded: those names legitimately changed (lua binds all report
# handler "__lua"). Key, modmask and flags must still match exactly.
hyprctl -j binds | jq -r '.[] | "\(.modmask)|\(.key)|\(.keycode)|\(.mouse)|\(.locked)|\(.repeat)|\(.release)|\(.description)"' | sort > "$S/binds-after.txt"
# The baseline was captured reading `.repeating`, which is always null — the json
# field is `repeat`. Blank that column on both sides so they line up. F11 was
# intentionally hardened after migration: it is allowed while locked and carries
# a description because it now runs a wake/retry/verify recovery wrapper.
awk -F'|' 'BEGIN{OFS="|"} {
    $6="-"
    if ($1 == "77" && $2 == "F11") {
        $5="true"
        $8="Wake Dell and switch to Titan DP-1"
    }
    print
}' "$S/binds-before.txt" | sort > "$S/bb.txt"
awk -F'|' 'BEGIN{OFS="|"} {$6="-"; print}' "$S/binds-after.txt"  | sort > "$S/ba.txt"
warn() { printf '  \033[33mwarn\033[0m %s\n' "$1"; }
if diff -q "$S/bb.txt" "$S/ba.txt" >/dev/null; then
    ok "all $(wc -l < "$S/binds-after.txt") binds identical to the .conf set"
else
    # The mouse flag on mouse:272/273 is EXPECTED to flip true->false: nothing in
    # 0.56.1 sets a keybind's mouse flag from lua (it is assigned only in the
    # legacy .conf parser, from bindm's `m` flag). Report that separately from a
    # genuine bind regression so this script keeps a clean signal.
    others=$(diff "$S/bb.txt" "$S/ba.txt" | command grep -E '^[<>]' | command grep -vE '\|mouse:(272|273)\|')
    if [ -z "$others" ]; then
        ok "mouse:272/273 report mouse=false (was true) — cosmetic only, drag/resize confirmed working 2026-07-29"
    else
        bad "bind set differs beyond the known mouse-flag change"
        echo "$others" | sed 's/^/       /' | head -20
    fi
fi

echo "== 3. config values match the .conf"
# getoption's json field names differ between parsers (.conf reports int/custom,
# lua reports bool/css/gradient), so compare the VALUE, not the field it sits in.
python3 - "$S" <<'PY'
import json,subprocess,sys,re
S=sys.argv[1]
def norm(js):
    try: d=json.loads(js)
    except Exception: return "<unparseable>"
    for k in ("bool","int","float","str","custom","css","gradient"):
        if d.get(k) is not None:
            v=d[k]
            if isinstance(v,bool):  return "1" if v else "0"
            if isinstance(v,float): return re.sub(r'\.?0+$','',f"{v:.6f}") or "0"
            return str(v)
    return "<unset>"
bad=0
for line in open(f"{S}/options-before.txt"):
    key,_,want_raw=line.partition(" = ")
    key=key.strip()
    if not key: continue
    want=norm(want_raw)
    got=norm(subprocess.run(["hyprctl","getoption","-j",key],
                            capture_output=True,text=True).stdout)
    if want==got: print(f"  \033[32mok\033[0m   {key} = {got}")
    else:
        bad+=1; print(f"  \033[31mFAIL\033[0m {key}\n       .conf: {want}\n       .lua : {got}")
sys.exit(min(bad,120))
PY
fail=$((fail+$?))

echo "== 4. monitors: same scale, position, resolution"
for n in DP-1 DP-2; do
    w=$(jq -c --arg n "$n" '.[]|select(.name==$n)|{scale,x,y,width,height,refreshRate}' "$S/monitors-before.json")
    g=$(hyprctl -j monitors | jq -c --arg n "$n" '.[]|select(.name==$n)|{scale,x,y,width,height,refreshRate}')
    # Legacy Hyprland reported scales rounded to two decimal places while Lua
    # preserves the configured precision (1.67 vs 1.6666666, for example).
    equivalent=$(jq -n --argjson w "$w" --argjson g "$g" '
        ($w.x == $g.x) and ($w.y == $g.y) and
        ($w.width == $g.width) and ($w.height == $g.height) and
        ((($w.scale - $g.scale) | fabs) < 0.01) and
        ((($w.refreshRate - $g.refreshRate) | fabs) < 0.01)
    ')
    [ "$equivalent" = true ] && ok "$n $g" || bad "$n
       .conf: $w
       .lua : $g"
done

echo "== 5. workspace rules identical"
jq -S 'sort_by(.workspaceString)' "$S/wsrules-before.json" > "$S/ws-b.json"
hyprctl -j workspacerules | jq -S 'sort_by(.workspaceString)' > "$S/ws-a.json"
if diff -q "$S/ws-b.json" "$S/ws-a.json" >/dev/null; then ok "all workspace rules identical"
else bad "workspace rules differ"; diff "$S/ws-b.json" "$S/ws-a.json" | sed 's/^/       /' | head -20; fi

echo "== 6. dispatcher argument tables construct"
# `hyprctl eval` NEVER returns the expression's value — it always prints "ok".
# It DOES surface lua errors, so assert inside and treat any non-"ok" output as a
# failure. (An earlier version of this script compared eval's output to a type
# name, so every single one of these "failed" for no reason.)
while IFS='|' read -r label expr; do
    [ -z "$label" ] && continue
    out=$(hyprctl eval "local d = $expr; assert(type(d) ~= 'nil', 'nil dispatcher')" 2>&1)
    [ "$out" = "ok" ] && ok "$label" || bad "$label -> $out"
done <<'EOF'
focus direction|hl.dsp.focus({ direction = "l" })
focus workspace selector|hl.dsp.focus({ workspace = "e+1" })
focus workspace previous|hl.dsp.focus({ workspace = "previous" })
fullscreen mode|hl.dsp.window.fullscreen({ mode = "fullscreen" })
maximized mode|hl.dsp.window.fullscreen({ mode = "maximized" })
window move direction|hl.dsp.window.move({ direction = "l" })
window move into_group|hl.dsp.window.move({ into_group = "l" })
window move out_of_group|hl.dsp.window.move({ out_of_group = true })
window move workspace|hl.dsp.window.move({ workspace = "special:magic" })
window move workspace silent|hl.dsp.window.move({ workspace = "special:magic", follow = false })
window resize relative|hl.dsp.window.resize({ x = 30, y = 0, relative = true })
window resize absolute|hl.dsp.window.resize({ x = 480, y = 700, relative = false })
window set_prop toggle|hl.dsp.window.set_prop({ prop = "opaque", value = "toggle" })
window drag (mouse bind)|hl.dsp.window.drag()
window resize (mouse bind)|hl.dsp.window.resize()
window center|hl.dsp.window.center()
window pin|hl.dsp.window.pin()
window float toggle|hl.dsp.window.float({ action = "toggle" })
cursor move|hl.dsp.cursor.move({ x = 100, y = 100 })
group toggle|hl.dsp.group.toggle()
group next|hl.dsp.group.next()
group active index|hl.dsp.group.active({ index = 1 })
workspace move monitor|hl.dsp.workspace.move({ monitor = "l" })
workspace toggle_special|hl.dsp.workspace.toggle_special("magic")
exit|hl.dsp.exit()
EOF

echo "== 7. helper calls used inside keybind closures"
while IFS='|' read -r expr label; do
    [ -z "$label" ] && continue
    out=$(hyprctl eval "$expr" 2>&1)
    [ "$out" = "ok" ] && ok "$label" || bad "$label -> $out"
done <<'EOF'
assert(type(hl.get_config("cursor.zoom_factor")) == "number")|zoom bind arithmetic (SUPER+CTRL+Z)
assert(type(hl.get_windows()) == "table")|close-all-windows (CTRL+ALT+Delete)
EOF

echo "== 8. no old-syntax hyprctl callers left outside the config"
# The check that would have caught the pia-launch.sh / cycle-scale.sh /
# fix-toolbox.sh / wlogout breakage: converting hyprland.conf is NOT enough.
# `hyprctl dispatch <name> <args>` and `hyprctl keyword` are both dead under the
# lua parser, and inside a script they fail silently.
hits=$(grep -rnE 'hyprctl[^|]*(dispatch +[a-z]|keyword +|--batch|setprop +)' \
        ~/.config/hypr/scripts ~/.config/waybar ~/.config/wlogout \
        ~/.config/systemd/user ~/.config/swaync 2>/dev/null \
        | grep -vE "hl\.dsp|hl\.monitor|hl\.config|hl\.dispatch|migration-check" \
        | grep -vE '^[^:]+:[0-9]+: *(#|--|//)')   # skip comments describing the old syntax
if [ -z "$hits" ]; then ok "no legacy hyprctl calls found"
else bad "legacy hyprctl calls still present (these fail silently):"; echo "$hits" | sed 's/^/       /'; fi

echo "== 9. non-retrying tray apps wait for Waybar's watcher"
# These five apps register their tray item only once. Three are launched directly
# from Lua; PIA and StreamController wait inside their dedicated wrappers.
LUA="$HOME/.config/hypr/hyprland.lua"
RESTART="$HOME/.config/hypr/scripts/restart-tray-apps.sh"
if command grep -F 'arch-update --tray' "$LUA" | command grep -q 'StatusNotifierWatcher'; then
    ok "Cachy-Update launch is watcher-aware"
else bad "Cachy-Update can race Waybar at login"; fi
if command grep -F 'polychromatic-helper --autostart' "$LUA" | command grep -q 'StatusNotifierWatcher'; then
    ok "Polychromatic launch is watcher-aware"
else bad "Polychromatic can race Waybar at login"; fi
TOOLBOX_CMD="/usr/bin/jetbrains-toolbox --jvm-args=$HOME/.config/JetBrains/Toolbox/toolbox.vmoptions --minimize"
if command grep -F "$TOOLBOX_CMD" "$LUA" | command grep -q 'StatusNotifierWatcher'; then
    ok "JetBrains Toolbox launch is watcher-aware and uses process-local JVM options"
else bad "JetBrains Toolbox login launch is stale or can race Waybar"; fi
if command grep -Fq 'busctl --user status org.kde.StatusNotifierWatcher' "$HOME/.config/hypr/scripts/pia-launch.sh"; then
    ok "PIA launch is watcher-aware"
else bad "PIA can race Waybar at login"; fi
if command grep -Fq 'xdotool windowunmap' "$HOME/.config/hypr/scripts/pia-launch.sh" \
        && ! command grep -Fq 'special:piahide' "$HOME/.config/hypr/scripts/pia-launch.sh"; then
    ok "PIA startup unmaps the dashboard so Show Window can remap it"
else bad "PIA startup can maroon the dashboard on a hidden workspace"; fi
if command grep -Fq 'busctl --user status org.kde.StatusNotifierWatcher' "$HOME/.config/systemd/user/streamcontroller.service"; then
    ok "StreamController launch is watcher-aware"
else bad "StreamController can race Waybar at login"; fi
if command grep -Fq "/usr/lib/arch-update/arch-update-tray" "$RESTART"; then
    ok "tray recovery targets the Cachy-Update 4.x process"
else bad "tray recovery still targets the removed pre-4.x Python process"; fi
if command grep -Fq "/usr/bin/polychromatic-tray-applet" "$RESTART" && command grep -Fq "polychromatic-helper --autostart" "$RESTART"; then
    ok "tray recovery restarts Polychromatic"
else bad "tray recovery omits Polychromatic"; fi
if command grep -Fq "$TOOLBOX_CMD" "$RESTART" \
        && ! command grep -Fq "$HOME/.local/share/JetBrains/Toolbox/bin/jetbrains-toolbox" "$RESTART" \
        && ! command grep -Fq 'GDK_SCALE=1' "$RESTART"; then
    ok "tray recovery uses the packaged Toolbox launcher and process-local JVM options"
else bad "tray recovery still uses an obsolete Toolbox launcher or scaling override"; fi

echo "== 10. no config errors in the current session log"
L=$(ls -t "$XDG_RUNTIME_DIR"/hypr/*/hyprland.log 2>/dev/null | head -1)
if [ -n "$L" ]; then
    errs=$(grep -iE '\[ERR|config ?error|unrecognized arguments|unknown config key' "$L" | head -10)
    [ -z "$errs" ] && ok "clean log" || bad "errors in log:
$(echo "$errs" | sed 's/^/       /')"
else bad "no hyprland log found"; fi

echo "== 11. graphical-session lifecycle and health"
# Not migration-specific, but this is the script run after a re-login. Bare
# Hyprland now owns a real graphical-session lifecycle even though the lingering
# user manager stays alive for Lerd and Hermes.

START="$HOME/.config/hypr/scripts/session-start.sh"
WLOGOUT="$HOME/.config/wlogout/layout"
if command grep -Fq 'session-start.sh' "$LUA" \
        && command grep -Fq 'hyprland.shutdown' "$LUA" \
        && command grep -Fq 'systemctl --user stop hyprland-session.target' "$LUA" \
        && ! command grep -Fq 'session-repair.sh' "$LUA"; then
    ok "Hyprland starts and stops the graphical-session lifecycle without login repair"
else
    bad "Hyprland lifecycle hooks are incomplete or session-repair still runs at login"
fi
if [ -x "$START" ] \
        && command grep -Fq 'dbus-update-activation-environment --systemd --all' "$START" \
        && command grep -Fq 'systemctl --user start hyprland-session.target' "$START"; then
    ok "session start serializes environment propagation before target activation"
else
    bad "session-start.sh is missing, non-executable, or incomplete"
fi
if command grep -Fq 'systemctl --user stop hyprland-session.target && hyprctl dispatch' "$WLOGOUT"; then
    ok "wlogout stops session services synchronously before compositor exit"
else
    bad "wlogout can exit Hyprland before session services stop"
fi

# (a) flatpak-session-helper caches the environment it was started with, so
# `flatpak-spawn --host hyprctl ...` inside any flatpak targets a dead socket.
helper_sig=$(tr '\0' '\n' < "/proc/$(systemctl --user show -p MainPID --value flatpak-session-helper.service)/environ" 2>/dev/null \
             | sed -n 's/^HYPRLAND_INSTANCE_SIGNATURE=//p')
if [ "$helper_sig" = "$HYPRLAND_INSTANCE_SIGNATURE" ]; then
    ok "flatpak-session-helper has the current instance signature"
else
    bad "flatpak-session-helper holds a STALE instance signature — flatpak apps calling
       hyprctl via flatpak-spawn will fail (StreamController spams ~5 errors/sec).
       helper: ${helper_sig:-<none>}
       live  : $HYPRLAND_INSTANCE_SIGNATURE
       fix   : systemctl --user restart flatpak-session-helper.service"
fi

# (b) Every session-only user service must both be active now and follow
# graphical-session.target down. WantedBy= alone only starts a service.
for u in streamcontroller.service cameractrlsd.service lerd-tray.service hyprwhspr.service wayscriber.service; do
    if ! systemctl --user list-unit-files "$u" &>/dev/null; then continue; fi
    state=$(systemctl --user is-active "$u" 2>/dev/null)
    [ "$state" = "active" ] && ok "$u active" \
        || bad "$u is $state after session start"
    partof=$(systemctl --user show -p PartOf --value "$u")
    [ "$partof" = "graphical-session.target" ] && ok "$u follows graphical-session.target down" \
        || bad "$u lacks PartOf=graphical-session.target"
done
if systemctl --user is-active --quiet hyprland-session.target graphical-session.target; then
    ok "Hyprland and graphical session targets active"
else
    bad "Hyprland or graphical session target inactive"
fi
if systemctl --user show -p ExecStop --value streamcontroller.service | command grep -Fq 'flatpak kill com.core447.StreamController'; then
    ok "StreamController explicitly releases its Flatpak payload on session stop"
else
    bad "StreamController can outlive its service and retain the Stream Deck handle"
fi
for u in lerd-ui.service hermes-gateway.service; do
    partof=$(systemctl --user show -p PartOf --value "$u")
    [ -z "$partof" ] && ok "$u remains outside the graphical lifecycle" \
        || bad "$u is unexpectedly coupled to $partof"
done

# (c) A flatpak holding a USB device that is killed abruptly at logout can leave
# the handle unusable: "TransportError: Failed to write feature report (-1)".
if lsusb 2>/dev/null | command grep -q '0fd9:006c'; then
    sclog=~/.var/app/com.core447.StreamController/data/logs/logs.log
    python3 -c "
import sys,os
l=open(os.path.expanduser('$sclog'),errors='replace').read().splitlines()
ends=[i for i,x in enumerate(l) if 'Finished loading app' in x]
if not ends: sys.exit(3)
# Deck initialization (including 'Loaded page') occurs BEFORE the completion
# marker. Inspect the entire latest startup generation, beginning after the
# previous completion marker, rather than only lines after the latest marker.
start=(ends[-2]+1) if len(ends)>1 else 0
current=l[start:]
if any('TransportError' in x for x in current): sys.exit(1)
if not any('Loaded page ' in x and ' on deck' in x for x in current): sys.exit(2)
sys.exit(0)" 2>/dev/null
    rc=$?
    if [ "$rc" -eq 1 ]; then
        bad "Stream Deck USB handle is stale (TransportError during latest startup).
       fix: systemctl --user stop streamcontroller.service && flatpak kill com.core447.StreamController
            usbreset 0fd9:006c && systemctl --user start streamcontroller.service"
    elif [ "$rc" -eq 2 ]; then
        bad "Stream Deck was not loaded during the latest StreamController startup"
    elif [ "$rc" -eq 3 ]; then
        bad "StreamController log has no completed startup marker"
    elif [ "$rc" -eq 0 ]; then
        ok "Stream Deck loaded in latest startup with no transport error"
    else
        bad "StreamController log could not be evaluated"
    fi
fi

echo
[ "$fail" -eq 0 ] && printf '\033[32mAll automated checks passed.\033[0m\n' \
                  || printf '\033[31m%d check(s) failed.\033[0m\n' "$fail"
cat <<'MANUAL'

Manual spot-checks (behaviour no API can confirm):
  SUPER + LMB drag / RMB resize    MOUSE BINDS — most important, see note below
  SUPER+slash                      cycle monitor scale      (was silently broken)
  open JetBrains Toolbox           repositions correctly    (was silently broken)
  reboot, then check PIA           hidden at startup; Show Window remaps
  wlogout -> Logout                exits cleanly            (was silently broken)
  SUPER+G then SUPER+ALT+Tab       group toggle + cycle
  SUPER+ALT+left / +ALT+G          move window into / out of group
  SUPER+SHIFT+ALT+left             move workspace to other monitor
  SUPER+BackSpace                  toggle window opacity (set_prop)
  SUPER+CTRL+Z / +CTRL+ALT+Z       zoom in 0.5 / reset
  SUPER+O                          float + pin in one press
  SUPER+F / SUPER+ALT+F            fullscreen vs maximize
  Print                            screenshot -> satty (proves permissions)

Note on mouse binds: `{ mouse = true }` is documented on the wiki but is NOT read
by hl.bind in 0.56.1 — verified against src/config/lua/bindings/
LuaBindingsToplevel.cpp at tag v0.56.1, where the opts parser reads
repeating/locked/release/click/drag/... and never "mouse". The flag is assigned
in exactly one place in the whole tree: the LEGACY parser, from bindm's `m`.
So binds report mouse=false under lua for everyone on 0.56.1.
RESOLVED 2026-07-29: purely cosmetic. SUPER+LMB drag and SUPER+RMB resize were
tested and behave correctly (no sticking) — Config::Actions::mouse handles
press+release itself off m_passPressed, independent of the flag.

Rollback is maintained in the Chezmoi Git history. Revert the reviewed Lua-migration
commit and apply only the affected Hyprland targets; do not resurrect the retired
hyprland.conf or fix-toolbox.sh by hand.
MANUAL
exit "$fail"
