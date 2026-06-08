# Windows Terminal setup (work laptop)

1. Install Windows Terminal (ships with Win11) and a Nerd Font (Terminess NF or MesloLGS NF).
2. Color schemes (auto-loaded, update-proof): copy `schemes.fragment.json` to
   `%LOCALAPPDATA%\Microsoft\Windows Terminal\Fragments\dotfiles\schemes.json`
3. Open Settings → "Open JSON file" and merge these into the OFFICIAL settings.json:
   - `profiles.defaults`: `"font": { "face": "Terminess Nerd Font Mono", "size": 16 }`,
     `"colorScheme": "Solarized Dark Higher Contrast"`, `"opacity": 80`, `"useAcrylic": true`
   - Set the Ubuntu/WSL profile as `defaultProfile`.
   - Globals: `"copyOnSelect": true`, `"copyFormatting": "none"`
   - Keybindings: Ctrl+C copy, Ctrl+V paste, Alt+Shift+D splitPane(duplicate), Ctrl+Shift+F find
