# CUSTOM START
PS1='\[\033[01;34m\]\u\[\033[00m\]@\[\033[01;32m\]\w\[\033[00m\]\$ '
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