# dotfiles

The dotfiles needed for my typical WSL setup.

## WLinux

1. Download and install Docker Desktop.
2. Install Pengwin
3. Run `pengwin-setup` and choose MAINTENANCE, PROGRAMMING, SERVICES, SETTINGS, and TOOLS
   1. For MAINTENTNACE, choose HOMEBACKUP
   2. For PROGRAMMING, choose NODEJS and RUBY (no need for Rails)
   3. For SERVICES, choose KEYCHAIN
   4. For SETTINGS, choose EXPLORER, COLORTOOL, and SHELLS
      1. For SHELLS, choose ZSH
   5. For TOOLS, choose CLOUDCLI, DOCKER, and POWERSHELL
4. ?? Install yarn: `npm install -g yarn@berry`
5. Install cowsay: `yarn global add cowsay`
6. Install lolcat: `gem install lolcat`
7. Install tmux
8. Install tmux-resurrect

---

## CMDer

### Tasks

* Task name: `{WSL::zsh}`
* Task parameters: `/icon "%USERPROFILE%\Pictures\pengwin.ico"`
* Command: `%LOCALAPPDATA%\wsltty\bin\mintty.exe --WSL= --configdir="%APPDATA%\wsltty" -~ -`

The "bash" task may have already been created.

* Task name: `WSL::bash`
* Task parameters: `-icon "%USERPROFILE%\AppData\Local\lxss\bash.ico"`
* Command: `set "PATH=%ConEmuBaseDirShort%\wsl;%PATH%" & %ConEmuBaseDirShort%\conemu-cyg-64.exe --wsl -cur_console:pm:/mnt`
