# dotfiles

The dotfiles needed for my typical WSL setup.

## CMDer

### Tasks

* Task name: `{WSL::zsh}`
* Task parameters: `/icon "%USERPROFILE%\Pictures\pengwin.ico"`
* Command: `%LOCALAPPDATA%\wsltty\bin\mintty.exe --WSL= --configdir="%APPDATA%\wsltty" -~ -`

The "bash" task may have already been created.

* Task name: `WSL::bash`
* Task parameters: `-icon "%USERPROFILE%\AppData\Local\lxss\bash.ico"`
* Command: `set "PATH=%ConEmuBaseDirShort%\wsl;%PATH%" & %ConEmuBaseDirShort%\conemu-cyg-64.exe --wsl -cur_console:pm:/mnt`
