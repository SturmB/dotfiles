"""Read-only profile rendering tests. No real secrets or bootstrap execution."""
import json
import pathlib
import re
import shutil
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory() as tmp:
    tmp = pathlib.Path(tmp)
    src = tmp / 'source'
    shutil.copytree(ROOT, src, ignore=shutil.ignore_patterns('.git', '.store', 'tests'))
    secrets = src / 'private_dot_secrets.tmpl'
    secrets.write_text(re.sub(r'{{ joinPath .*? }}', 'TEST_ONLY', secrets.read_text()))
    for profile, distro in [('stream', 'ubuntu'), ('work', 'ubuntu'), ('personal', 'cachyos'), ('server', 'ubuntu')]:
        dest = tmp / profile
        dest.mkdir()
        config = tmp / (profile + '.json')
        data = dict(profile=profile, personal=profile in ('personal', 'stream'), work=profile in ('personal', 'work'), server=profile == 'server')
        config.write_text(json.dumps({'data': data}))
        base = ['chezmoi', '--config', str(config), '--source', str(src), '--destination', str(dest), '--persistent-state', str(tmp / 'state.db'), '--override-data', json.dumps({'chezmoi': {'osRelease': {'id': distro}}})]
        def run(*args, input=None):
            return subprocess.run(base + list(args), input=input, text=True, capture_output=True, check=True).stdout
        def render(name):
            return run('execute-template', '--file', str(src / name))
        managed = set(run('managed').splitlines())
        assert run('execute-template', '{{ .chezmoi.osRelease.id }}') == distro
        if profile == 'stream':
            for name in ['.bashrc', '.profile', '.gitconfig-work', '.config/php', '.config/hypr', '.config/waybar', '.config/atlassian', '.config/espanso/match/IEL.yml', '.local/bin/edit-clipboard-image', '.local/bin/hyprlock-logged', '.claude/skills/lerd', '.claude/commands/prs-to-review.md']:
                assert name not in managed, name
            for name in ['.zshrc', '.config/starship.toml', '.claude/settings.json', '.claude/commands/code-recheck.md', '.config/mise/config.toml']:
                assert name in managed, name
            assert 'intxlog' not in render('dot_gitconfig.tmpl')
        if profile == 'personal':
            assert '.config/hypr/hyprland.lua' in managed
            assert '.gitconfig-work' not in managed
            assert '.local/bin/edit-clipboard-image' in managed
        if profile == 'work':
            assert '.config/php/conf.d/99-custom.ini' in managed
            assert '.config/hypr' not in managed
        if profile == 'server':
            assert '.profile' in managed and '.bashrc' in managed
            assert '.ssh/id_ed25519_iel' not in managed
        import tomllib
        zshrc = render('dot_zshrc.tmpl')
        subprocess.run(['zsh', '-n'], input=zshrc, text=True, check=True)
        subprocess.run(['sh', '-n'], input=render('dot_profile.tmpl'), text=True, check=True)
        assert zshrc.count('autoload -Uz compinit && compinit') == 1
        assert zshrc.index('fpath=') < zshrc.index('autoload -Uz compinit')
        assert zshrc.index('autoload -Uz compinit') < zshrc.index('source "$HOME/.bun/_bun"')
        assert zshrc.index('export PATH="$BUN_INSTALL/bin:$PATH"') < zshrc.index('export PATH="$HOME/.local/share/lerd/bin:$PATH"')
        assert zshrc.count('export PATH="$HOME/.local/share/lerd/bin:$PATH"') == 1
        assert 'command -v starship' in zshrc and 'command -v zoxide' in zshrc
        gitconfig = render('dot_gitconfig.tmpl')
        assert ('pager = hunk pager' in gitconfig) == (profile == 'personal')
        gitfile = tmp / 'rendered.gitconfig'
        gitfile.write_text(gitconfig)
        subprocess.run(['git', 'config', '--file', str(gitfile), '--list'], capture_output=True, check=True)
        # Host defaults must not leak Titan's runtime opt-out to other machines.
        for hostname in ['titan', 'another-host']:
            override = json.dumps({'chezmoi': {'hostname': hostname, 'osRelease': {'id': distro}}})
            text = run('--override-data', override, 'execute-template', '--file', str(src / 'dot_config/mise/config.toml.tmpl'))
            mise = tomllib.loads(text)
            assert bool(mise.get('tools')) == (hostname != 'titan')
            assert ('PHP_INI_SCAN_DIR' in mise.get('env', {})) == (hostname != 'titan' and distro != 'ubuntu')
            assert '--with-imap' not in mise.get('env', {}).get('PHP_CONFIGURE_OPTIONS', '')
        print('PASS:', profile, 'shell syntax, completion ordering, Hunk isolation, mise host isolation')
        forbidden_targets = {'.gitconfig-work', '.ssh/id_ed25519_iel', '.ssh/id_ed25519_iel.pub', '.config/atlassian/credentials', '.config/espanso/match/IEL.yml', '.claude/commands/guideline-triage.md', '.claude/commands/review-multi-prs.md'}
        assert not forbidden_targets.intersection(managed)
        for name in ['private_dot_ssh/private_config.tmpl', 'dot_gitconfig.tmpl', 'dot_aliases.tmpl', 'dot_zshrc.tmpl', 'run_once_before_install-packages.sh.tmpl']:
            assert not re.search(r'intxlog|github.com-iel|JIRA_AUTH_TYPE|jira-cli|confcli|nexus-sail|nexus-lerd', render(name), re.I), name
        for hostname in ['titan', 'another-host']:
            override = json.dumps({'chezmoi': {'hostname': hostname, 'osRelease': {'id': distro}}})
            script = run('--override-data', override, 'execute-template', '--file', str(src / 'run_onchange_after_install-mise-tools.sh.tmpl'))
            assert ('mise install node' in script) == (hostname != 'titan')
            if hostname == 'titan':
                result = subprocess.run(['bash'], input=script, text=True, capture_output=True, check=True)
                assert 'provisioning disabled' in result.stdout
        print('PASS:', profile, 'IEL targets/consumers absent; disabled mise installer executes no installs')
        zprofile = render('dot_zprofile.tmpl')
        assert ('xdg-ubuntustudio-dirs.sh' in zprofile) == (distro == 'ubuntu')
        subprocess.run(['zsh', '-n'], input=zprofile, text=True, check=True)
        # Exercise the distro hook when available, with a clean login environment.
        if distro == 'ubuntu' and pathlib.Path('/etc/profile.d/xdg-ubuntustudio-dirs.sh').exists():
            (dest / '.zprofile').write_text(zprofile)
            probe = subprocess.run(['zsh', '-lc', 'print -r -- "$XDG_CONFIG_DIRS"'], env={'HOME': str(dest), 'ZDOTDIR': str(dest), 'PATH': '/usr/bin:/bin', 'DESKTOP_SESSION': 'plasma'}, text=True, capture_output=True, check=True)
            assert '/etc/xdg/xdg-plasma' in probe.stdout.split(':')
        rendered = render('private_dot_secrets.tmpl')
        names = set(re.findall(r'^export (\w+)=', rendered, re.M))
        expected = {'stream': {'OPENROUTER_API_KEY'}, 'work': set(), 'personal': {'YNAB_API_KEY', 'OPENROUTER_API_KEY'}, 'server': set()}[profile]
        assert names == expected, (profile, names)
        for name in ['run_once_before_install-packages.sh.tmpl', 'run_onchange_after_install-php-apt.sh.tmpl', 'run_onchange_after_install-mise-tools.sh.tmpl']:
            subprocess.run(['bash', '-n'], input=render(name), text=True, check=True)
        assert ('php8.5-cli' in render('run_onchange_after_install-php-apt.sh.tmpl')) == (profile == 'work')
        settings = dest / '.claude/settings.json'
        settings.parent.mkdir(parents=True, exist_ok=True)
        settings.write_text('{"permissions":{"allow":["Read"]}}')
        settings.chmod(0o600)
        run('apply', '--force', '--exclude=scripts', str(settings))
        assert settings.stat().st_mode & 0o777 == 0o600
        assert json.loads(settings.read_text())['permissions'] == {'allow': ['Read']}
        print('PASS:', profile, 'Claude settings apply preserves private mode and local permissions')
        print('PASS:', profile, 'target filtering, credential selection, rendered script syntax')
    # The existing permission policy must survive the Claude settings merge.
    current = {'permissions': {'defaultMode': 'default', 'allow': ['Read']}, 'theme': 'dark'}
    merged = json.loads(subprocess.run(['bash', str(src/'dot_claude/modify_private_settings.json')], input=json.dumps(current), text=True, capture_output=True, check=True).stdout)
    assert merged['permissions'] == current['permissions']
    assert merged['theme'] == 'dark'
    assert merged['hooks']['PreToolUse']
    print('PASS: Claude merge preserves existing permission settings')
