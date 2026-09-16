-- Hyprland config — converted from hyprland.conf 2026-07-29 (hyprlang → Lua).
-- Refer to the wiki for more information.
-- https://wiki.hypr.land/Configuring/
--
-- Local references for this exact version:
--   /usr/share/hypr/stubs/hl.meta.lua  — every config key, dispatcher and option type
--   /usr/share/hypr/hyprland.lua       — upstream example config
-- Check syntax without starting a session: Hyprland --verify-config


------------------
---- MONITORS ----
------------------

-- See https://wiki.hypr.land/Configuring/Basics/Monitors/
hl.monitor({ output = "DP-1", mode = "preferred", position = "0x0",        scale = 1.066667 }) -- MSI (left, primary)
hl.monitor({ output = "DP-2", mode = "preferred", position = "auto-right", scale = 1.666667 }) -- Dell (right)

hl.config({
    xwayland = {
        force_zero_scaling = true,
    },
})

-- Bind workspaces to monitors: 1-5 on MSI, 6-10 on Dell
for i = 1, 10 do
    hl.workspace_rule({
        workspace = tostring(i),
        monitor   = i <= 5 and "DP-1" or "DP-2",
        default   = (i == 1 or i == 6) or nil,
    })
end


---------------------
---- MY PROGRAMS ----
---------------------

local terminal    = "ghostty"
local fileManager = "dolphin"
local menu        = "hyprlauncher"


-------------------
---- AUTOSTART ----
-------------------

-- See https://wiki.hypr.land/Configuring/Basics/Autostart/
hl.on("hyprland.start", function()
    -- Propagate the new Wayland environment before starting the graphical-session
    -- lifecycle. The helper is synchronous internally, so D-Bus/systemd services cannot
    -- start with the previous Hyprland instance signature. hyprland-session.target pulls
    -- graphical-session.target up; the shutdown hook below releases it again on logout.
    hl.exec_cmd("~/.config/hypr/scripts/session-start.sh")

    -- waybar wrapped in a respawn loop — it periodically SIGSEGVs in libgdk-3
    -- (GTK3/Wayland event-dispatch bug). The script restarts it and re-kicks the
    -- tray apps on each crash. See ~/.config/hypr/scripts/waybar-respawn.sh.
    hl.exec_cmd("~/.config/hypr/scripts/waybar-respawn.sh")
    -- hyprpaper replaced by Azote — see Hyprland Wallpaper Setup note
    hl.exec_cmd("~/.azotebg-hyprland")
    hl.exec_cmd("swaync")
    hl.exec_cmd("/usr/lib/polkit-kde-authentication-agent-1")
    hl.exec_cmd("swayosd-server")
    -- Wake up ksecretd via the PAM-provided socket so org.freedesktop.secrets
    -- (KWallet's Secret Service bridge) is on the bus before clients like 1Password start.
    -- KDE/GNOME do this via /etc/xdg/autostart/pam_kwallet_init.desktop; Hyprland doesn't.
    hl.exec_cmd("/usr/lib/pam_kwallet_init")

    -- Apps
    -- 1Password (Electron) creates its tray icon once at startup and doesn't retry
    -- if org.kde.StatusNotifierWatcher isn't on the bus yet. Because waybar (which
    -- owns that name) and 1password both launch at the same moment, this is a race —
    -- lost after logout/login (warm cache), usually won on a cold reboot.
    -- Wait for the watcher to exist before launching.
    -- Keep the explicit `bash -c`: `&>` is a bashism and hl.exec_cmd only guarantees `sh -c`.
    hl.exec_cmd("bash -c 'until busctl --user status org.kde.StatusNotifierWatcher &>/dev/null; do sleep 0.1; done; exec 1password --silent'")
    -- Cachy-Update registers its tray item once and exits if Waybar's watcher is
    -- not ready. This watcher wait was accidentally omitted in the Lua migration.
    hl.exec_cmd("bash -c 'until busctl --user status org.kde.StatusNotifierWatcher &>/dev/null; do sleep 0.1; done; exec arch-update --tray'")
    -- Polychromatic ships an XDG autostart entry, but bare Hyprland leaves
    -- xdg-desktop-autostart.target inactive. Use its official helper so the app's
    -- tray.autostart preference remains authoritative, after Waybar owns the watcher.
    hl.exec_cmd("bash -c 'until busctl --user status org.kde.StatusNotifierWatcher &>/dev/null; do sleep 0.1; done; exec polychromatic-helper --autostart'")
    hl.exec_cmd("/opt/yubico-authenticator/authenticator --hidden")
    hl.exec_cmd("dropbox")
    hl.exec_cmd("easyeffects --gapplication-service")
    -- Espanso is owned by Hyprland so it exits with this graphical session. Do not
    -- enable its lingering default.target user unit or add an XDG-autostart duplicate.
    hl.exec_cmd("espanso launcher")
    -- The Comet Pro KVM disconnects EVDEV devices on a Titan → Aurora → Titan
    -- switch. Watch Espanso's log and replace its stale worker after reconnect.
    hl.exec_cmd("~/.config/hypr/scripts/espanso-hotplug-watchdog.sh")
    -- Toolbox registers its tray item only at process startup; wait until Waybar
    -- owns the watcher. Keep the mixed-monitor XWayland scale override local to
    -- Toolbox so IDEs launched from it do not inherit a global JVM option.
    hl.exec_cmd("bash -c 'until busctl --user status org.kde.StatusNotifierWatcher &>/dev/null; do sleep 0.1; done; exec /usr/bin/jetbrains-toolbox --jvm-args=/home/kerban/.config/JetBrains/Toolbox/toolbox.vmoptions --minimize'")
    hl.exec_cmd("steam -silent")
    -- Vesktop — wait for the StatusNotifierWatcher before launching. Vesktop's
    -- package launcher follows the Electron major version shipped by vesktop-bin;
    -- keep the Ozone environment outside it so Wayland tray registration works.
    -- If waybar hasn't claimed the watcher yet, SNI registration may silently fail.
    hl.exec_cmd("bash -c 'until busctl --user status org.kde.StatusNotifierWatcher &>/dev/null; do sleep 0.1; done; exec env ELECTRON_OZONE_PLATFORM_HINT=auto /usr/bin/vesktop --start-minimized'")
    -- hl.exec_cmd("lan-mouse --daemon --capture-backend layer-shell")
    hl.exec_cmd("~/.config/hypr/scripts/pia-launch.sh")
    hl.exec_cmd("udiskie --tray")

end)

-- Fallback for direct compositor exits. The normal wlogout path stops this target
-- synchronously before dispatching exit; this hook covers other graceful shutdown paths.
-- The target has StopWhenUnneeded=yes, and session-only services use PartOf= so they stop
-- while the compositor is still completing shutdown. Persistent Lerd/Hermes units are not
-- part of this target and remain alive under the lingering user manager.
hl.on("hyprland.shutdown", function()
    hl.exec_cmd("systemctl --user stop hyprland-session.target")
end)


-------------------------------
---- ENVIRONMENT VARIABLES ----
-------------------------------

-- See https://wiki.hypr.land/Configuring/Advanced-and-Cool/Environment-variables/

hl.env("XCURSOR_SIZE", "24")
hl.env("HYPRCURSOR_SIZE", "24")
hl.env("QT_QPA_PLATFORMTHEME", "kde")
hl.env("GDK_SCALE", "1")
hl.env("STEAM_FORCE_DESKTOPUI_SCALING", "1.5")

-- NVIDIA Wayland
hl.env("__GLX_VENDOR_LIBRARY_NAME", "nvidia")
hl.env("NVD_BACKEND", "direct")

hl.config({
    cursor = {
        no_hardware_cursors = true,
    },
})


-----------------------
----- PERMISSIONS -----
-----------------------

-- See https://wiki.hypr.land/Configuring/Advanced-and-Cool/Permissions/
-- Please note permission changes here require a Hyprland restart and are not applied on-the-fly
-- for security reasons

-- hl.config({
--     ecosystem = {
--         enforce_permissions = true,
--     },
-- })

hl.permission("/usr/(bin|local/bin)/grim", "screencopy", "allow")
hl.permission("/usr/(lib|libexec|lib64)/xdg-desktop-portal-hyprland", "screencopy", "allow")
hl.permission("/usr/(bin|local/bin)/wf-recorder", "screencopy", "allow")
-- hl.permission("/usr/(bin|local/bin)/hyprpm", "plugin", "allow")


-----------------------
---- LOOK AND FEEL ----
-----------------------

-- Refer to https://wiki.hypr.land/Configuring/Basics/Variables/
hl.config({
    general = {
        gaps_in  = 5,
        gaps_out = 20,

        border_size = 2,

        col = {
            active_border   = { colors = { "rgba(33ccffee)", "rgba(00ff99ee)" }, angle = 45 },
            inactive_border = "rgba(595959aa)",
        },

        -- Set to true to enable resizing windows by clicking and dragging on borders and gaps
        resize_on_border = false,

        -- Please see https://wiki.hypr.land/Configuring/Advanced-and-Cool/Tearing/ before you turn this on
        -- Allow tearing for reduced input lag in games (requires `immediate` window rule per-app)
        allow_tearing = true,

        layout = "dwindle",
    },

    decoration = {
        rounding       = 10,
        rounding_power = 2,

        -- Change transparency of focused and unfocused windows
        active_opacity   = 1.0,
        inactive_opacity = 1.0,

        shadow = {
            enabled      = true,
            range        = 4,
            render_power = 3,
            color        = "rgba(1a1a1aee)",
        },

        blur = {
            enabled  = true,
            size     = 3,
            passes   = 1,
            vibrancy = 0.1696,
        },
    },

    animations = {
        enabled = true,
    },
})

-- Default curves, see https://wiki.hypr.land/Configuring/Advanced-and-Cool/Animations/
hl.curve("easeOutQuint",   { type = "bezier", points = { { 0.23, 1 },    { 0.32, 1 } } })
hl.curve("easeInOutCubic", { type = "bezier", points = { { 0.65, 0.05 }, { 0.36, 1 } } })
hl.curve("linear",         { type = "bezier", points = { { 0, 0 },       { 1, 1 } } })
hl.curve("almostLinear",   { type = "bezier", points = { { 0.5, 0.5 },   { 0.75, 1 } } })
hl.curve("quick",          { type = "bezier", points = { { 0.15, 0 },    { 0.1, 1 } } })

hl.animation({ leaf = "global",        enabled = true, speed = 10,   bezier = "default" })
hl.animation({ leaf = "border",        enabled = true, speed = 5.39, bezier = "easeOutQuint" })
hl.animation({ leaf = "windows",       enabled = true, speed = 4.79, bezier = "easeOutQuint" })
hl.animation({ leaf = "windowsIn",     enabled = true, speed = 4.1,  bezier = "easeOutQuint", style = "popin 87%" })
hl.animation({ leaf = "windowsOut",    enabled = true, speed = 1.49, bezier = "linear",       style = "popin 87%" })
hl.animation({ leaf = "fadeIn",        enabled = true, speed = 1.73, bezier = "almostLinear" })
hl.animation({ leaf = "fadeOut",       enabled = true, speed = 1.46, bezier = "almostLinear" })
hl.animation({ leaf = "fade",          enabled = true, speed = 3.03, bezier = "quick" })
hl.animation({ leaf = "layers",        enabled = true, speed = 3.81, bezier = "easeOutQuint" })
hl.animation({ leaf = "layersIn",      enabled = true, speed = 4,    bezier = "easeOutQuint", style = "fade" })
hl.animation({ leaf = "layersOut",     enabled = true, speed = 1.5,  bezier = "linear",       style = "fade" })
hl.animation({ leaf = "fadeLayersIn",  enabled = true, speed = 1.79, bezier = "almostLinear" })
hl.animation({ leaf = "fadeLayersOut", enabled = true, speed = 1.39, bezier = "almostLinear" })
hl.animation({ leaf = "workspaces",    enabled = true, speed = 1.94, bezier = "almostLinear", style = "fade" })
hl.animation({ leaf = "workspacesIn",  enabled = true, speed = 1.21, bezier = "almostLinear", style = "fade" })
hl.animation({ leaf = "workspacesOut", enabled = true, speed = 1.94, bezier = "almostLinear", style = "fade" })
hl.animation({ leaf = "zoomFactor",    enabled = true, speed = 7,    bezier = "quick" })

-- Ref https://wiki.hypr.land/Configuring/Basics/Workspace-Rules/
-- "Smart gaps" / "No gaps when only"
-- uncomment all if you wish to use that.
-- hl.workspace_rule({ workspace = "w[tv1]", gaps_out = 0, gaps_in = 0 })
-- hl.workspace_rule({ workspace = "f[1]",   gaps_out = 0, gaps_in = 0 })
-- hl.window_rule({
--     name  = "no-gaps-wtv1",
--     match = { float = false, workspace = "w[tv1]" },
--     border_size = 0,
--     rounding    = 0,
-- })
-- hl.window_rule({
--     name  = "no-gaps-f1",
--     match = { float = false, workspace = "f[1]" },
--     border_size = 0,
--     rounding    = 0,
-- })

hl.config({
    -- See https://wiki.hypr.land/Configuring/Layouts/Dwindle-Layout/ for more
    dwindle = {
        preserve_split = true,
    },

    -- See https://wiki.hypr.land/Configuring/Layouts/Master-Layout/ for more
    master = {
        new_status = "master",
    },

    misc = {
        force_default_wallpaper  = -1,    -- Set to 0 or 1 to disable the anime mascot wallpapers
        disable_hyprland_logo    = false, -- If true disables the random hyprland logo / anime girl background. :(
        disable_splash_rendering = true,
    },
})


---------------
---- INPUT ----
---------------

hl.config({
    input = {
        kb_layout  = "us",
        kb_variant = "",
        kb_model   = "",
        kb_options = "compose:ralt",
        kb_rules   = "",

        numlock_by_default = true,
        follow_mouse       = 2,

        sensitivity = 0, -- -1.0 - 1.0, 0 means no modification.

        touchpad = {
            natural_scroll = false,
        },
    },
})

-- See https://wiki.hypr.land/Configuring/Basics/Variables/#gestures
hl.gesture({ fingers = 3, direction = "horizontal", action = "workspace" })

-- Example per-device config
-- See https://wiki.hypr.land/Configuring/Advanced-and-Cool/Devices/ for more
hl.device({ name = "epic-mouse-v1", sensitivity = -0.5 })


---------------------
---- KEYBINDINGS ----
---------------------

-- Omarchy-style keybindings — https://learn.omacom.io/2/the-omarchy-manual/53/hotkeys
local mainMod = "SUPER"

-- ── Show keybindings ──
hl.bind(mainMod .. " + K", hl.dsp.exec_cmd('wofi -d --prompt "Keybindings" < ~/.config/hypr/keybindings.txt'))

-- ── Navigating ──
hl.bind(mainMod .. " + Space",  hl.dsp.exec_cmd(menu))
hl.bind(mainMod .. " + Escape", hl.dsp.exec_cmd("pidof wlogout && pkill wlogout || wlogout -p layer-shell"))
hl.bind(mainMod .. " + CTRL + L", hl.dsp.exec_cmd("~/.local/bin/hyprlock-logged"))
hl.bind(mainMod .. " + W", hl.dsp.window.close())
-- Close all windows
hl.bind("CTRL + ALT + Delete", function()
    for _, w in ipairs(hl.get_windows()) do
        hl.dispatch(hl.dsp.window.close({ window = w }))
    end
end)
hl.bind(mainMod .. " + T", hl.dsp.window.float({ action = "toggle" }))
-- Float + pin in one press
hl.bind(mainMod .. " + O", function()
    hl.dispatch(hl.dsp.window.float({ action = "toggle" }))
    hl.dispatch(hl.dsp.window.pin())
end)
hl.bind(mainMod .. " + F",       hl.dsp.window.fullscreen({ mode = "fullscreen" }))
hl.bind(mainMod .. " + ALT + F", hl.dsp.window.fullscreen({ mode = "maximized" }))

-- Move focus
hl.bind(mainMod .. " + left",  hl.dsp.focus({ direction = "l" }))
hl.bind(mainMod .. " + right", hl.dsp.focus({ direction = "r" }))
hl.bind(mainMod .. " + up",    hl.dsp.focus({ direction = "u" }))
hl.bind(mainMod .. " + down",  hl.dsp.focus({ direction = "d" }))

-- Swap windows
hl.bind(mainMod .. " + SHIFT + left",  hl.dsp.window.move({ direction = "l" }))
hl.bind(mainMod .. " + SHIFT + right", hl.dsp.window.move({ direction = "r" }))
hl.bind(mainMod .. " + SHIFT + up",    hl.dsp.window.move({ direction = "u" }))
hl.bind(mainMod .. " + SHIFT + down",  hl.dsp.window.move({ direction = "d" }))

-- Resize windows
hl.bind(mainMod .. " + equal",         hl.dsp.window.resize({ x =  30, y =   0, relative = true }), { repeating = true })
hl.bind(mainMod .. " + minus",         hl.dsp.window.resize({ x = -30, y =   0, relative = true }), { repeating = true })
hl.bind(mainMod .. " + SHIFT + equal", hl.dsp.window.resize({ x =   0, y =  30, relative = true }), { repeating = true })
hl.bind(mainMod .. " + SHIFT + minus", hl.dsp.window.resize({ x =   0, y = -30, relative = true }), { repeating = true })

-- Workspaces + move window to workspace
for i = 1, 10 do
    local key = i % 10 -- 10 maps to key 0
    hl.bind(mainMod .. " + " .. key,             hl.dsp.focus({ workspace = i }))
    hl.bind(mainMod .. " + SHIFT + " .. key,     hl.dsp.window.move({ workspace = i }))
end
hl.bind(mainMod .. " + Tab",         hl.dsp.focus({ workspace = "e+1" }))
hl.bind(mainMod .. " + SHIFT + Tab", hl.dsp.focus({ workspace = "e-1" }))
hl.bind(mainMod .. " + CTRL + Tab",  hl.dsp.focus({ workspace = "previous" }))

-- Move workspace to other monitor
hl.bind(mainMod .. " + SHIFT + ALT + left",  hl.dsp.workspace.move({ monitor = "l" }))
hl.bind(mainMod .. " + SHIFT + ALT + right", hl.dsp.workspace.move({ monitor = "r" }))
hl.bind(mainMod .. " + SHIFT + ALT + up",    hl.dsp.workspace.move({ monitor = "u" }))
hl.bind(mainMod .. " + SHIFT + ALT + down",  hl.dsp.workspace.move({ monitor = "d" }))

-- Window grouping
hl.bind(mainMod .. " + G",         hl.dsp.group.toggle())
hl.bind(mainMod .. " + ALT + G",   hl.dsp.window.move({ out_of_group = true }))
hl.bind(mainMod .. " + ALT + Tab", hl.dsp.group.next())
for i = 1, 4 do
    hl.bind(mainMod .. " + ALT + " .. i, hl.dsp.group.active({ index = i }))
end
hl.bind(mainMod .. " + ALT + left",  hl.dsp.window.move({ into_group = "l" }))
hl.bind(mainMod .. " + ALT + right", hl.dsp.window.move({ into_group = "r" }))
hl.bind(mainMod .. " + ALT + up",    hl.dsp.window.move({ into_group = "u" }))
hl.bind(mainMod .. " + ALT + down",  hl.dsp.window.move({ into_group = "d" }))
hl.bind(mainMod .. " + CTRL + left",  hl.dsp.focus({ direction = "l" }))
hl.bind(mainMod .. " + CTRL + right", hl.dsp.focus({ direction = "r" }))
hl.bind(mainMod .. " + CTRL + up",    hl.dsp.focus({ direction = "u" }))
hl.bind(mainMod .. " + CTRL + down",  hl.dsp.focus({ direction = "d" }))

-- Scratchpad
hl.bind(mainMod .. " + S",       hl.dsp.workspace.toggle_special("magic"))
hl.bind(mainMod .. " + ALT + S", hl.dsp.window.move({ workspace = "special:magic" }))

-- Zoom
hl.bind(mainMod .. " + CTRL + Z", function()
    hl.config({ cursor = { zoom_factor = (hl.get_config("cursor.zoom_factor") or 1) + 0.5 } })
end)
hl.bind(mainMod .. " + CTRL + ALT + Z", function()
    hl.config({ cursor = { zoom_factor = 1 } })
end)

-- Cycle monitor scaling
hl.bind(mainMod .. " + slash", hl.dsp.exec_cmd("~/.config/hypr/scripts/cycle-scale.sh"))

-- Scroll through workspaces with mouse
hl.bind(mainMod .. " + mouse_down", hl.dsp.focus({ workspace = "e+1" }))
hl.bind(mainMod .. " + mouse_up",   hl.dsp.focus({ workspace = "e-1" }))

-- Mouse move/resize
hl.bind(mainMod .. " + mouse:272", hl.dsp.window.drag(),   { mouse = true })
hl.bind(mainMod .. " + mouse:273", hl.dsp.window.resize(), { mouse = true })

-- ── System Controls ──
hl.bind(mainMod .. " + CTRL + A", hl.dsp.exec_cmd("pavucontrol"))
hl.bind(mainMod .. " + CTRL + B", hl.dsp.exec_cmd(terminal .. " -e bluetui"))
hl.bind(mainMod .. " + CTRL + W", hl.dsp.exec_cmd(terminal .. " -e nmtui"))
hl.bind(mainMod .. " + CTRL + T", hl.dsp.exec_cmd(terminal .. " -e btop"))

-- ── 1Password ──
hl.bind("CTRL + SHIFT + Space", hl.dsp.exec_cmd("1password --quick-access"))

-- ── App Launches ──
hl.bind(mainMod .. " + Return",         hl.dsp.exec_cmd(terminal))
hl.bind(mainMod .. " + SHIFT + Return", hl.dsp.exec_cmd("zen-browser"))
hl.bind(mainMod .. " + SHIFT + F",      hl.dsp.exec_cmd(fileManager))
hl.bind(mainMod .. " + SHIFT + O",      hl.dsp.exec_cmd("obsidian"))
hl.bind(mainMod .. " + SHIFT + D",      hl.dsp.exec_cmd(terminal .. " -e lazydocker"))

-- ── Clipboard ──
hl.on("hyprland.start", function()
    hl.exec_cmd("wl-paste --watch cliphist store")
end)
hl.bind(mainMod .. " + CTRL + V", hl.dsp.exec_cmd("cliphist list | wofi -d | cliphist decode | wl-copy"))

-- ── Emoji Picker ──
hl.bind(mainMod .. " + period", hl.dsp.exec_cmd("smile"))

-- ── Capture ──
local sattyOut = "~/Pictures/Screenshots/%Y-%m/Screenshot_%Y%m%d_%H%M%S.png"
local sattyArgs = "satty -f - -o " .. sattyOut .. " --copy-command wl-copy --early-exit --disable-notifications"
local mkShotDir = "mkdir -p ~/Pictures/Screenshots/$(date +%Y-%m)"
hl.bind("Print",              hl.dsp.exec_cmd(mkShotDir .. " && grimblast save area - | " .. sattyArgs))
hl.bind("SHIFT + Print",      hl.dsp.exec_cmd(mkShotDir .. " && grimblast save screen - | " .. sattyArgs))
hl.bind("ALT + Print",        hl.dsp.exec_cmd("~/.config/hypr/scripts/record.sh"))
hl.bind("CTRL + Print",       hl.dsp.exec_cmd(mkShotDir .. " && sleep 3 && grim -c - | " .. sattyArgs))
hl.bind(mainMod .. " + Print", hl.dsp.exec_cmd("hyprpicker -a"))

-- ── Notifications (swaync) ──
hl.bind(mainMod .. " + comma",         hl.dsp.exec_cmd("swaync-client --close-latest"))
hl.bind(mainMod .. " + SHIFT + comma", hl.dsp.exec_cmd("swaync-client --close-all"))
hl.bind(mainMod .. " + CTRL + comma",  hl.dsp.exec_cmd("swaync-client --toggle-dnd"))
hl.bind(mainMod .. " + ALT + comma",   hl.dsp.exec_cmd("swaync-client --toggle-panel"))

-- ── Screen Annotation (Wayscriber) ──
hl.bind(mainMod .. " + D", hl.dsp.exec_cmd("wayscriber --daemon-toggle"))

-- hyprwhspr — Toggle mode (added by hyprwhspr setup)
-- Press once to start, press again to stop
hl.bind("SUPER + ALT + D", hl.dsp.exec_cmd("/usr/lib/hyprwhspr/config/hyprland/hyprwhspr-tray.sh record"),
    { description = "Speech-to-text" })

-- ── Style / Toggles ──
hl.bind(mainMod .. " + BackSpace", hl.dsp.window.set_prop({ prop = "opaque", value = "toggle" }))
hl.bind(mainMod .. " + SHIFT + Space", hl.dsp.exec_cmd("killall -SIGUSR1 waybar"))
-- Restart waybar: just kill it — waybar-respawn.sh brings it back + kicks the
-- tray apps. Do NOT spawn waybar here too, or it races a double instance.
hl.bind(mainMod .. " + SHIFT + B", hl.dsp.exec_cmd("killall -q waybar"))
hl.bind(mainMod .. " + SHIFT + T", hl.dsp.exec_cmd("~/.config/hypr/scripts/restart-tray-apps.sh"))
hl.bind(mainMod .. " + CTRL + N",  hl.dsp.exec_cmd("pkill gammastep || gammastep -O 4500"))
hl.bind(mainMod .. " + CTRL + I",  hl.dsp.exec_cmd("pkill -SIGUSR1 hypridle || true"))

-- ── Monitor Input Switching (DDC/CI) ──
hl.bind(mainMod .. " + CTRL + ALT + SHIFT + F12",
    hl.dsp.exec_cmd('flock -w 75 "${XDG_RUNTIME_DIR:-/tmp}/dell-monitor-input.lock" ddcutil --model "DELL U2723QE" setvcp 60 0x11')) -- Aurora (Dell HDMI-1)
hl.bind(mainMod .. " + CTRL + ALT + SHIFT + F11",
    hl.dsp.exec_cmd("~/.config/hypr/scripts/switch-dell-to-titan.sh"),
    { locked = true, description = "Wake Dell and switch to Titan DP-1" })

-- ── Volume and brightness via SwayOSD ──
hl.bind("XF86AudioRaiseVolume",  hl.dsp.exec_cmd("swayosd-client --output-volume raise"),      { repeating = true, locked = true })
hl.bind("XF86AudioLowerVolume",  hl.dsp.exec_cmd("swayosd-client --output-volume lower"),      { repeating = true, locked = true })
hl.bind("XF86AudioMute",         hl.dsp.exec_cmd("swayosd-client --output-volume mute-toggle"), { repeating = true, locked = true })
hl.bind("XF86AudioMicMute",      hl.dsp.exec_cmd("swayosd-client --input-volume mute-toggle"),  { repeating = true, locked = true })
hl.bind("XF86MonBrightnessUp",   hl.dsp.exec_cmd("swayosd-client --brightness raise"),          { repeating = true, locked = true })
hl.bind("XF86MonBrightnessDown", hl.dsp.exec_cmd("swayosd-client --brightness lower"),          { repeating = true, locked = true })

-- ── Media keys ──
hl.bind("XF86AudioNext",  hl.dsp.exec_cmd("playerctl next"),       { locked = true })
hl.bind("XF86AudioPause", hl.dsp.exec_cmd("playerctl play-pause"), { locked = true })
hl.bind("XF86AudioPlay",  hl.dsp.exec_cmd("playerctl play-pause"), { locked = true })
hl.bind("XF86AudioPrev",  hl.dsp.exec_cmd("playerctl previous"),   { locked = true })


--------------------------------
---- WINDOWS AND WORKSPACES ----
--------------------------------

-- See https://wiki.hypr.land/Configuring/Basics/Window-Rules/
-- and https://wiki.hypr.land/Configuring/Basics/Workspace-Rules/

hl.window_rule({
    -- Ignore maximize requests from all apps. You'll probably like this.
    name  = "suppress-maximize-events",
    match = { class = ".*" },

    suppress_event = "maximize",
})

hl.window_rule({
    -- Fix some dragging issues with XWayland
    name  = "fix-xwayland-drags",
    match = {
        class      = "^$",
        title      = "^$",
        xwayland   = true,
        float      = true,
        fullscreen = false,
        pin        = false,
    },

    no_focus = true,
})

-- Smile emoji picker
hl.window_rule({
    name   = "smile-emoji-picker",
    match  = { class = "^it\\.mijorus\\.smile$" },
    float  = true,
    center = true,
})

-- Satty screenshot annotation
hl.window_rule({
    name   = "satty-float",
    match  = { class = "^com\\.gabm\\.satty$" },
    float  = true,
    center = true,
})

-- PIA VPN — cap the tray popup height (XWayland, already floats)
hl.window_rule({
    name     = "pia-vpn-popup",
    match    = { class = "privateinternetaccess" },
    max_size = { 300, 500 },
})

-- JetBrains Toolbox — keep its default size and natural right-edge placement.
-- The process-local JVM option in the autostart command stabilizes XWayland
-- scaling across monitors. Toolbox settles partly over Waybar after each tray
-- restore, so make one delayed y-only correction; never resize, focus, or move
-- the cursor.
hl.window_rule({
    name  = "jetbrains-toolbox",
    match = { class = "^jetbrains-toolbox$" },
    float = true,
})

local toolboxMoveTimers = {}
hl.on("window.open", function(window)
    if window.class ~= "jetbrains-toolbox" then return end

    local address = window.address
    toolboxMoveTimers[address] = hl.timer(function()
        local current = hl.get_window("address:" .. address)
        if current and current.mapped then
            hl.dispatch(hl.dsp.window.move({
                x = current.at.x,
                y = 36,
                relative = false,
                window = current,
            }))
        end
        toolboxMoveTimers[address] = nil
    end, { timeout = 750, type = "oneshot" })
end)

-- Hyprland-run window rule
hl.window_rule({
    name  = "move-hyprland-run",
    match = { class = "hyprland-run" },

    move  = "20 monitor_h-120",
    float = true,
})

-- Vesktop — autostarts on WS1 at login; pin it to 6 so tray-restore lands there.
-- silent = don't drag focus to WS6 at boot.
hl.window_rule({
    name      = "vesktop-workspace",
    match     = { class = "^vesktop$" },
    workspace = "6 silent",
})

-- Allow tearing for games (reduces input lag)
-- Disabled 2026-07-18: this catch-all forced immediate (torn) scanout on EVERY
-- Steam game, overriding in-game V-Sync. Re-enable / narrow match.class per-game
-- if you want tearing back for specific low-latency titles.
-- hl.window_rule({
--     name      = "gaming-tearing",
--     match     = { class = "^(steam_app_.*)$" },
--     immediate = true,
-- })

-- Cyclopean: The Great Abyss (steam_app_2958790) — XWayland maps its window
-- off-screen (x=-3449, then re-placed at -2999 after the splash) so it's invisible.
-- ACTUAL FIX is the gamescope Steam launch option (see notes); under gamescope the
-- visible window is class 'gamescope', so this rule does NOT fire. Kept only as a
-- fallback: if you ever run WITHOUT gamescope, this forces the game on-screen
-- fullscreen instead of invisible. Safe to delete if you never run it bare.
hl.window_rule({
    name       = "cyclopean-fullscreen-fallback",
    match      = { class = "^(steam_app_2958790)$" },
    fullscreen = true,
})
