------------------
---- MONITORS ----
------------------

-- See https://wiki.hypr.land/Configuring/Basics/Monitors/
hl.monitor({ output = "DP-1", mode = "preferred", position = "0x0",        scale = 1.07 }) -- MSI (left, primary)
hl.monitor({ output = "DP-2", mode = "preferred", position = "auto-right", scale = 1.67 }) -- Dell (right)

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

-- nwg-displays owns only its generated monitor layout, never the workspace rules
-- or XWayland policy above. Keep the defaults when no GUI layout exists yet.
-- Its separate workspaces.lua is deliberately not loaded.
local layout = io.open(os.getenv("HOME") .. "/.config/hypr/monitors.lua", "r")
if layout then
    layout:close()
    require("monitors")
end

-- Aurora capture card: mirror the MSI gaming monitor, not a third desktop.
-- Keep this after the nwg-displays layout so GUI saves do not override it.
hl.monitor({
    output = "HDMI-A-1",
    mode = "3840x2160@60",
    position = "4704x0", -- Fallback position if mirroring is later removed.
    scale = 1,
    transform = 0,
    vrr = 0,
    mirror = "DP-1",
    bitdepth = 8,
    cm = "srgb",
})
