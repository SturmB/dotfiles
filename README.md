# Portable dotfiles

Managed with chezmoi. Review the first diff before applying: scripts install packages and may change the login shell.

## Bootstrap

Authorize a per-machine GitHub SSH key and verify `git ls-remote git@github.com:SturmB/dotfiles.git HEAD`. Personal, work and stream profiles need the age identity at `~/key.txt` (mode 600), transferred privately over SSH; server profiles render no credentials.

```sh
sh -c "$(curl -fsLS https://get.chezmoi.io)" -- -b "$HOME/.local/bin" init --ssh SturmB
export PATH="$HOME/.local/bin:$PATH"
chezmoi status
chezmoi diff --skip-secrets
# After review:
chezmoi apply
```

Choose `stream` for Aurora. `init` does not clone over an existing Git source directory, even an empty one. Inspect `chezmoi source-path` and its Git remote if initialization appears to do nothing; preserve existing work rather than deleting it.

## Profiles

- `personal`: personal and development tooling, OpenRouter and Jira; no former-employer credentials.
- `work`: generic development tooling and the Jira API token; no personal API credentials.
- `stream`: shared zsh/CLI and Claude configuration, Node/mise, personal Git/SSH, OpenRouter only. Preserve existing `.profile` and `.bashrc`; exclude work identity/snippets/agent workflows, PHP configuration, and (by default) Hyprland and clipboard-image helpers.
- `server`: no API credentials or employer SSH key. Retains the existing server shell behavior; this is not an exhaustive minimal-server profile audit.

`hyprland` and `clipboardImage` in local chezmoi `[data]` are explicit optional capabilities. Defaults preserve CachyOS personal workstation behavior and disable them elsewhere. Existing configs without those keys get the same defaults; no config regeneration is required just to obtain the exclusions.

Ignored files are left unmanaged, not deleted. Removing a capability does not uninstall packages or erase previously deployed files/secrets. Review already-deployed hosts separately.

## Omarchy

Omarchy (`ID=omarchy`) has its own bootstrap branch; choose `personal` for Defiant.
It installs zsh and shared CLI dependencies with `pacman --needed`, plus RTK when
missing, then clones Oh My Zsh and its three external plugins into user-local
paths. It does not run the Oh My Zsh installer or `chsh`: Bash remains the login
shell. Launch `zsh` explicitly after review to try the shared shell configuration.

Defaults preserve Omarchy's `.bashrc`, `.profile`, Ghostty configuration (including
its theme/includes), `.config/mise`, btop, and tmux (`.tmux.conf` and
`.config/tmux`). Micro and PHP configuration are also excluded on Omarchy.
Espanso remains managed, including the shared expansions and Titan's custom
`vaniam.yml` expansion (personal/stream profiles only).
The CachyOS Hyprland/Waybar and clipboard-image targets stay disabled;
Omarchy's desktop is not replaced.
Personal credentials remain OpenRouter, and generic personal/development
tooling remains managed. These exclusions are not a blanket protection for every
existing file: review the remaining diff, especially shared application settings.

Global mise provisioning is disabled on Omarchy, including the after-install
script, so existing Omarchy/project runtime setup is left alone. To deliberately
replace the global mise config and provision its declared runtimes, set
`miseGlobalTools = true` in the local chezmoi `[data]` after reviewing that config
and its PHP/Node requirements. Older chezmoi configs without this key get the same
safe default; explicit `false` keeps both config and runtime installation disabled.

Use the preview-first bootstrap above, not `init --apply` on an existing host.
For staged configuration reconciliation, review exact paths and use
`chezmoi apply --exclude=scripts -- <approved-paths>`; package bootstrap is a
separate sudo/network action. Chezmoi records `run_once` scripts by their
rendered content hash: unchanged content does not rerun, but
changed content reruns on the next script-enabled apply, even on a host that
already ran the bootstrap. Template or local data changes can change that hash.
Keep scripts excluded until the rendered bootstrap and its sudo/network actions
have been reviewed and approved; do not rely on a previous run as protection.
Nothing here changes terminal launch settings, logs out the session, migrates
pre-existing managed files, or removes previously deployed files.

## Maintenance and testing

Pull source changes without automatic apply, then review status/diff. Commit and push intentional source changes; avoid blind updates over app-managed configuration.

```sh
python3 "$(chezmoi source-path)/tests/profiles.py"
python3 "$(chezmoi source-path)/tests/omarchy.py"
```

Tests render all four profiles (including Omarchy) in temporary directories, substitute a non-secret fixture for encrypted values, check target membership/credential variable selection and shell syntax, and exercise the Claude settings merge. Omarchy tests also execute generated bootstrap and mise scripts with an isolated PATH of command stubs, checking package selection, native startup-file byte preservation, local plugin paths, repeat-run behavior, and runtime opt-in/opt-out. Runtime zsh fixtures source plugins from default and custom directories; a harmless isolated chezmoi fixture verifies persistent `run_once` rendered-content tracking. They do not access the network, install real packages, change shells, or apply the live configuration.

The bootstrap requires working network access and sudo for packages. RTK installation is mandatory for the Claude hook; Ubuntu package installation includes jq and gh. When scripts are excluded, newly added dependencies must be installed separately or through a reviewed, approved script-enabled apply.
