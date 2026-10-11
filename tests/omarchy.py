"""Omarchy renders and executable bootstrap tests; no network or real installs."""
import json
import pathlib
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


class OmarchyTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.tmp = pathlib.Path(self.temp.name)
        self.src = self.tmp / 'source'
        shutil.copytree(ROOT, self.src, ignore=shutil.ignore_patterns('.git', '.store', 'tests'))
        secrets = self.src / 'private_dot_secrets.tmpl'
        secrets.write_text(re.sub(r'{{ joinPath .*? }}', 'TEST_ONLY', secrets.read_text()))
        self.home = self.tmp / 'home'
        self.home.mkdir()
        self.config = self.tmp / 'config.json'
        self.configure()

    def configure(self, profile='personal', **extra):
        data = dict(profile=profile, personal=profile in ('personal', 'stream'),
                    work=profile in ('personal', 'work'), server=profile == 'server')
        data.update(extra)
        self.config.write_text(json.dumps({'data': data}))

    def run_chezmoi(self, *args):
        command = ['chezmoi', '--config', str(self.config), '--source', str(self.src),
                   '--destination', str(self.home), '--persistent-state', str(self.tmp / 'state.db'),
                   '--override-data', json.dumps({'chezmoi': {'hostname': 'defiant', 'osRelease': {'id': 'omarchy'}}})]
        return subprocess.run(command + list(args), text=True, capture_output=True, check=True).stdout

    def render(self, name):
        return self.run_chezmoi('execute-template', '--file', str(self.src / name))

    def test_preserves_native_configuration_by_default(self):
        for profile in ('personal', 'work', 'stream', 'server'):
            with self.subTest(profile=profile):
                self.configure(profile)
                import tomllib
                # Init-only prompt functions require execute-template --init.
                text = self.run_chezmoi('execute-template', '--init', '--promptChoice',
                                        'Machine profile=' + profile, '--file',
                                        str(self.src / '.chezmoi.toml.tmpl'))
                initialized = tomllib.loads(text)['data']
                self.assertFalse(initialized['hyprland'])
                self.assertFalse(initialized['clipboardImage'])
                managed = set(self.run_chezmoi('managed').splitlines())
                for target in ('.bashrc', '.profile', '.config/ghostty/config', '.config/mise/config.toml',
                               '.config/hypr/hyprland.lua', '.config/waybar/config.jsonc',
                               '.local/bin/edit-clipboard-image', '.local/bin/hyprlock-logged'):
                    self.assertNotIn(target, managed)
                for target in ('.zshrc', '.config/zsh/common.zsh', '.config/starship.toml'):
                    self.assertIn(target, managed)
                installer = self.render('run_onchange_after_install-mise-tools.sh.tmpl')
                result = subprocess.run(['bash'], input=installer, text=True, capture_output=True, check=True)
                self.assertIn('provisioning disabled', result.stdout)
                self.assertNotIn('mise install node', installer)
                names = set(re.findall(r'^export (\w+)=', self.render('private_dot_secrets.tmpl'), re.M))
                expected = {'personal': {'YNAB_API_KEY', 'OPENROUTER_API_KEY'},
                            'stream': {'OPENROUTER_API_KEY'}, 'work': set(), 'server': set()}
                self.assertEqual(names, expected[profile])
        self.configure(miseGlobalTools=True)
        self.assertIn('.config/mise/config.toml', self.run_chezmoi('managed').splitlines())
        self.assertIn('mise install node', self.render('run_onchange_after_install-mise-tools.sh.tmpl'))

    def test_excludes_optional_application_config_but_keeps_espanso(self):
        excluded = ('.config/btop', '.tmux.conf', '.config/tmux', '.config/micro', '.config/php')
        # Include a tmux config-directory fixture even if the repository only has
        # .tmux.conf today; exclusions must protect future nested targets too.
        tmux = self.src / 'dot_config/tmux'
        tmux.mkdir(exist_ok=True)
        (tmux / 'tmux.conf').write_text('# test fixture\n')
        for profile in ('personal', 'work', 'stream', 'server'):
            with self.subTest(profile=profile):
                self.configure(profile)
                managed = set(self.run_chezmoi('managed').splitlines())
                for target in excluded:
                    with self.subTest(target=target):
                        self.assertFalse(any(name == target or name.startswith(target + '/')
                                             for name in managed), target)
                for target in ('.config/espanso/config/default.yml',
                               '.config/espanso/match/base.yml', '.config/espanso/match/personal.yml'):
                    self.assertIn(target, managed)

    def stub_environment(self, rtk_present=True):
        bin_dir = self.tmp / 'stub-bin'
        bin_dir.mkdir()
        log = self.tmp / 'commands.log'
        log.touch()
        # Deliberately no system PATH: package managers, network, account changes,
        # and runtime installation can only reach our logging stubs.
        for name in ('bash', 'sh', 'mkdir', 'cp', 'chmod'):
            executable = shutil.which(name)
            assert executable is not None, name
            (bin_dir / name).symlink_to(executable)
        def stub(name, body):
            target = bin_dir / name
            target.write_text('#!/bin/bash\n' + body + '\n')
            target.chmod(0o755)
        for name in ('sudo', 'apt', 'pacman', 'chsh', 'ssh-keygen', 'mise', 'starship'):
            stub(name, 'printf "%s\\n" "' + name + ' $*" >> "$COMMAND_LOG"')
        stub('git', 'printf "%s\\n" "git $*" >> "$COMMAND_LOG"\n/bin/mkdir -p "${@: -1}"')
        stub('rtk-fixture', 'exit 0')
        if rtk_present:
            stub('rtk', 'exit 0')
        stub('curl', '''printf "%s\\n" "curl $*" >> "$COMMAND_LOG"
case "$*" in
  *rtk-ai/rtk/master/install.sh*)
    printf '%s\\n' 'mkdir -p "$HOME/.local/bin"; cp "$STUB_BIN/rtk-fixture" "$HOME/.local/bin/rtk"; chmod +x "$HOME/.local/bin/rtk"' ;;
  *) printf 'unexpected network request\\n' >&2; exit 97 ;;
esac''')
        return dict(HOME=str(self.home), PATH=str(bin_dir), SHELL='/bin/bash',
                    STUB_BIN=str(bin_dir), COMMAND_LOG=str(log)), log

    def test_plugin_sources_execute_with_default_and_custom_directories(self):
        env, log = self.stub_environment()
        self.configure('server')
        # Keep runtime source tests closed to host executables and startup files.
        tput = self.tmp / 'stub-bin/tput'
        tput.write_text('#!/bin/bash\nexit 0\n')
        tput.chmod(0o755)
        zsh = shutil.which('zsh')
        self.assertIsNotNone(zsh)
        common = self.home / '.config/zsh/common.zsh'
        common.parent.mkdir(parents=True)
        common.write_text(self.render('dot_config/zsh/common.zsh.tmpl'))
        (self.home / '.aliases').write_text('')
        zshrc = self.home / '.zshrc'
        zshrc.write_text(self.render('dot_zshrc.tmpl'))
        bootstrap = self.tmp / 'bootstrap.sh'
        bootstrap.write_text(self.render('run_once_before_install-packages.sh.tmpl'))
        bootstrap.chmod(0o755)
        for custom in (False, True):
            with self.subTest(custom=custom):
                if custom:
                    # Remove the default fixture to detect fallback to hardcoded paths.
                    shutil.rmtree(self.home / '.oh-my-zsh/custom')
                    env['ZSH_CUSTOM'] = str(self.home / 'custom plugins')
                plugin_root = pathlib.Path(env.get('ZSH_CUSTOM', self.home / '.oh-my-zsh/custom'))
                subprocess.run([str(bootstrap)], env=env, capture_output=True, text=True, check=True)
                (self.home / '.oh-my-zsh/oh-my-zsh.sh').write_text('typeset -ga loaded; loaded+=(omz)\n')
                for plugin in ('zsh-autosuggestions', 'zsh-history-substring-search', 'zsh-syntax-highlighting'):
                    plugin_dir = plugin_root / 'plugins' / plugin
                    self.assertTrue(plugin_dir.is_dir())
                    (plugin_dir / (plugin + '.zsh')).write_text('loaded+=(' + plugin + ')\n')
                # Completion initialization is outside this plugin-path fixture's scope.
                result = subprocess.run([zsh, '-f', '-c',
                    'autoload() { :; }; compinit() { :; }; source "$HOME/.zshrc"; printf "%s\\n" "${loaded[@]}"'],
                    env=env, capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stderr, '')
                self.assertEqual(result.stdout.splitlines(), ['omz', 'zsh-autosuggestions',
                    'zsh-history-substring-search', 'zsh-syntax-highlighting'])

    def test_mise_opt_in_and_opt_out_execute_matching_policy(self):
        env, log = self.stub_environment()
        for enabled in (False, True):
            with self.subTest(enabled=enabled):
                self.configure(miseGlobalTools=enabled)
                managed = set(self.run_chezmoi('managed').splitlines())
                self.assertEqual('.config/mise/config.toml' in managed, enabled)
                generated = self.tmp / 'install-mise-tools.sh'
                generated.write_text(self.render('run_onchange_after_install-mise-tools.sh.tmpl'))
                generated.chmod(0o755)
                log.write_text('')
                result = subprocess.run([str(generated)], env=env, text=True, capture_output=True, check=True)
                self.assertEqual(log.read_text().splitlines(), ['mise install node', 'mise install'] if enabled else [])
                self.assertEqual('provisioning disabled' in result.stdout, not enabled)

    def test_once_script_persistent_state_tracks_rendered_content(self):
        env, _ = self.stub_environment()
        # Only this harmless fixture is applied, never the repository's targets.
        source = self.tmp / 'once-source'
        source.mkdir()
        template = source / 'run_once_before_probe.sh.tmpl'
        template.write_text('#!/bin/bash\nset -eu\nprintf "%s\\n" "{{ .revision }}" >> "$HOME/once.log"\n')
        config = self.tmp / 'once-config.json'
        command = [shutil.which('chezmoi'), '--config', str(config), '--source', str(source),
                   '--destination', str(self.home), '--persistent-state', str(self.tmp / 'once-state.db'),
                   '--no-tty', 'apply']
        config.write_text(json.dumps({'data': {'revision': 'first'}}))
        def apply():
            result = subprocess.run(command, env=env, text=True, capture_output=True, check=True)
            self.assertEqual(result.stderr, '')
            return (self.home / 'once.log').read_text().splitlines()
        self.assertEqual(apply(), ['first'])
        self.assertEqual(apply(), ['first'])
        # The template itself is unchanged: changing data changes its rendered hash.
        config.write_text(json.dumps({'data': {'revision': 'second'}}))
        self.assertEqual(apply(), ['first', 'second'])
        self.assertEqual(apply(), ['first', 'second'])

    def test_readme_warns_changed_once_script_can_rerun(self):
        readme = (self.src / 'README.md').read_text()
        self.assertIn('rendered content hash', readme)
        self.assertIn('changed content reruns on the next script-enabled apply', readme)
        self.assertNotIn('will not automatically rerun this new branch', readme)

    def test_bootstrap_installs_arch_packages_and_local_plugins_without_chsh(self):
        env, log = self.stub_environment(rtk_present=False)
        sentinels = {'.bashrc': b'# native Bash sentinel\r\nexport NATIVE=1\n',
                     '.profile': b'# native login sentinel\n\n# preserve trailing bytes\x00'}
        for name, content in sentinels.items():
            (self.home / name).write_bytes(content)
        script = self.render('run_once_before_install-packages.sh.tmpl')
        generated = self.tmp / 'install-packages.sh'
        generated.write_text(script)
        generated.chmod(0o755)
        subprocess.run(['/bin/bash', '-n', str(generated)], check=True)
        result = subprocess.run([str(generated)], env=env, text=True, capture_output=True)
        calls = log.read_text().splitlines()
        packages = next((line for line in calls if line.startswith('sudo pacman ')), '')
        self.assertTrue(packages, f'Omarchy never used pacman: {calls}')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stderr, '')
        for package in ('zsh', 'git', 'curl', 'unzip', 'starship', 'jq', 'github-cli',
                        'fzf', 'ripgrep', 'fd', 'bat', 'zoxide', 'eza', 'lsd'):
            self.assertIn(package, packages.split())
        self.assertIn('--needed', packages.split())
        self.assertTrue((self.home / '.local/bin/rtk').is_file())
        self.assertIn('[install] rtk', result.stdout)
        self.assertNotIn('no apt', result.stdout)
        self.assertFalse(any(line.startswith(('apt ', 'chsh ', 'ssh-keygen ', 'mise ')) for line in calls))
        self.assertFalse(any('apt ' in line for line in calls))
        self.assertTrue((self.home / '.oh-my-zsh').is_dir())
        for plugin in ('zsh-autosuggestions', 'zsh-syntax-highlighting', 'zsh-history-substring-search'):
            self.assertTrue((self.home / '.oh-my-zsh/custom/plugins' / plugin).is_dir())
        self.assertEqual(sum(line.startswith('git clone ') for line in calls), 4)
        common = self.render('dot_config/zsh/common.zsh.tmpl')
        self.assertIn('export ZSH="$HOME/.oh-my-zsh"', common)
        self.assertNotIn('/usr/share/oh-my-zsh', common)
        for name in ('dot_zshrc.tmpl', 'dot_config/zsh/common.zsh.tmpl', 'dot_zprofile.tmpl'):
            subprocess.run(['zsh', '-n'], input=self.render(name), text=True, check=True)
        for name, content in sentinels.items():
            self.assertEqual((self.home / name).read_bytes(), content)
        # Repeating the generated executable must not reclone or reinstall RTK.
        log.write_text('')
        second = subprocess.run([str(generated)], env=env, text=True, capture_output=True, check=True)
        self.assertNotIn('[install] rtk', second.stdout)
        self.assertFalse(any(line.startswith(('git ', 'curl ')) for line in log.read_text().splitlines()))
        for name, content in sentinels.items():
            self.assertEqual((self.home / name).read_bytes(), content)


if __name__ == '__main__':
    unittest.main(verbosity=2)
