# Setup fzf
# ---------
if [[ ! "$PATH" == */home/sturm/.fzf/bin* ]]; then
  export PATH="${PATH:+${PATH}:}/home/sturm/.fzf/bin"
fi

# Auto-completion
# ---------------
[[ $- == *i* ]] && source "/home/sturm/.fzf/shell/completion.zsh" 2> /dev/null

# Key bindings
# ------------
source "/home/sturm/.fzf/shell/key-bindings.zsh"
