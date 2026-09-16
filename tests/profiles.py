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
            assert '.gitconfig-work' in managed
            assert '.local/bin/edit-clipboard-image' in managed
        if profile == 'work':
            assert '.config/php/conf.d/99-custom.ini' in managed
            assert '.config/hypr' not in managed
        if profile == 'server':
            assert '.profile' in managed and '.bashrc' in managed
            assert '.ssh/id_ed25519_iel' not in managed
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
        expected = {'stream': {'OPENROUTER_API_KEY'}, 'work': {'JIRA_API_TOKEN', 'COMPOSER_AUTH'}, 'personal': {'JIRA_API_TOKEN', 'COMPOSER_AUTH', 'YNAB_API_KEY', 'OPENROUTER_API_KEY'}, 'server': set()}[profile]
        assert names == expected, (profile, names)
        for name in ['run_once_before_install-packages.sh.tmpl', 'run_onchange_after_install-php-apt.sh.tmpl', 'run_onchange_after_install-mise-tools.sh.tmpl']:
            subprocess.run(['bash', '-n'], input=render(name), text=True, check=True)
        assert ('php8.5-cli' in render('run_onchange_after_install-php-apt.sh.tmpl')) == (profile == 'work')
        print('PASS:', profile, 'target filtering, credential selection, rendered script syntax')
    # The existing permission policy must survive the Claude settings merge.
    current = {'permissions': {'defaultMode': 'default', 'allow': ['Read']}, 'theme': 'dark'}
    merged = json.loads(subprocess.run(['bash', str(src/'dot_claude/modify_settings.json')], input=json.dumps(current), text=True, capture_output=True, check=True).stdout)
    assert merged['permissions'] == current['permissions']
    assert merged['theme'] == 'dark'
    assert merged['hooks']['PreToolUse']
    print('PASS: Claude merge preserves existing permission settings')
