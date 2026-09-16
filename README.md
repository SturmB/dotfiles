# Portable dotfiles

Managed with chezmoi. Review the first diff before applying: scripts install packages and may change the login shell.

## Bootstrap

Authorize a per-machine GitHub SSH key and verify `git ls-remote git@github.com:SturmB/dotfiles.git HEAD`. Non-server profiles currently need the age identity at `~/key.txt` (mode 600), transferred privately over SSH.

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

- `personal`: personal and work tooling, work credentials, YNAB and OpenRouter.
- `work`: work tooling and credentials, no personal API credentials.
- `stream`: shared zsh/CLI and Claude configuration, Node/mise, personal Git/SSH, OpenRouter only. Preserve existing `.profile` and `.bashrc`; exclude work identity/snippets/agent workflows, PHP configuration, and (by default) Hyprland and clipboard-image helpers.
- `server`: no API credentials or managed work SSH key. Retains the existing server shell behavior; this is not an exhaustive minimal-server profile audit.

`hyprland` and `clipboardImage` in local chezmoi `[data]` are explicit optional capabilities. Defaults preserve CachyOS personal workstation behavior and disable them elsewhere. Existing configs without those keys get the same defaults; no config regeneration is required just to obtain the exclusions.

Ignored files are left unmanaged, not deleted. Removing a capability does not uninstall packages or erase previously deployed files/secrets. Review already-deployed hosts separately.

## Maintenance and testing

Pull source changes without automatic apply, then review status/diff. Commit and push intentional source changes; avoid blind updates over app-managed configuration.

```sh
python3 "$(chezmoi source-path)/tests/profiles.py"
```

Tests render profiles in temporary directories, substitute a non-secret fixture for encrypted values, check target membership/credential variable selection and shell syntax, and exercise the Claude settings merge. They do not install packages, change shells, or apply the live configuration.

The bootstrap requires working network access and sudo for packages. RTK installation is mandatory for the Claude hook; Ubuntu package installation includes jq and gh. Existing hosts that already ran a `run_once` bootstrap may need newly added dependencies installed separately.
