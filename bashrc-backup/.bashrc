# Custom settings
# -----------------------------------------------------------------------
export KUBE_EDITOR=nano

# Load alias file
if [ -f ~/.bash-aliases ]; then
  . ~/.bash-aliases
fi

# Load functions file
if [ -f ~/.bash-functions ]; then
  . ~/.bash-functions
fi

alias alihelp='cat ~/.bashrc-aliases'
alias funhelp='cat ~/.bashrc-functions'