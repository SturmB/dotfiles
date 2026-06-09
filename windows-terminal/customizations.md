# Windows Terminal setup (work laptop)

1. Install Windows Terminal (ships with Win11) and a **Mono** Nerd Font, then select it as the WT font.
   - **Use the `…Mono` variant** (e.g. *Terminess Nerd Font Mono*, *MesloLGS NF*, *CaskaydiaMono Nerd Font*, *JetBrainsMono Nerd Font Mono*).
   - Why Mono: non-Mono Nerd Fonts render OS/tool icons as **double-width** glyphs, which get **clipped** by the powerline separators in Windows Terminal's strict character grid (the OS icon shows cut off). The `Mono` variants force every glyph to a single cell, so icons fit cleanly.
2. Color schemes (auto-loaded, update-proof): copy `schemes.fragment.json` to
   `%LOCALAPPDATA%\Microsoft\Windows Terminal\Fragments\dotfiles\schemes.json`
3. Open Settings → "Open JSON file" and merge these into the OFFICIAL settings.json:
   - `profiles.defaults`: `"font": { "face": "Terminess Nerd Font Mono", "size": 16 }`,
     `"colorScheme": "Solarized Dark Higher Contrast"`, `"opacity": 80`, `"useAcrylic": true`
   - Set the Ubuntu/WSL profile as `defaultProfile`.
   - Globals: `"copyOnSelect": true`, `"copyFormatting": "none"`
   - Keybindings: Ctrl+C copy, Ctrl+V paste, Alt+Shift+D splitPane(duplicate), Ctrl+Shift+F find
