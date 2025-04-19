# CUSTOM START
export KUBE_EDITOR=nano

# Load alias file
if [ -f ~/.bashrc-aliases ]; then
  . ~/.bashrc-aliases
fi

# Load functions file
if [ -f ~/.bashrc-functions ]; then
  . ~/.bashrc-functions
fi

alias aliases='cat ~/.bashrc-aliases'
alias functions='cat ~/.bashrc-functions'
# CUSTOM END