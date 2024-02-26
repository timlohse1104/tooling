# Bashrc Backup

List of useful aliases and functions for bash shell.

# 📜Table of Contents

- [🔥Spotlight](#spotlight)
- [🏷️Aliases](#aliases)
- [🔧Functions](#functions)

## 🔥[Spotlight](#spotlight)

Fancy git log with graph

- `alias gl='git log --graph --abbrev-commit --decorate --format=format:"%C(bold blue)%h%C(reset) - %C(bold green)(%ar)%C(reset) %C(white)%s%C(reset) %C(dim white)- %an%C(reset)%C(bold yellow)%d%C(reset)" --all'`

## 🏷️[Aliases](#aliases)

### Base

- `alias ll='ls -alF'`
- `alias c='clear'`
- `alias h='history'`
- `alias k='kubectl'`
- `alias g='git'`

### Git

- `alias gs='git status'`
- `alias gac='git add . && git commit -m'`
- `alias gp1='git pull'`
- `alias gp2='git push'`
- `alias gco='git checkout'`
- `alias gcob='git switch -c'`

## 🔧[Functions](#functions)

### Kubernetes Logs

1. **Kubernetes logs of all pods in namespace**

Code

```bash
function kl() {
  kubectl logs -n $1
}
```

Call

```bash
kl <namespace>
```

2. **Watch kubernetes logs of all pods in namespace**

Code

```bash
function kwl() {
  watch "kubectl logs -n $1"
}
```

Call

```bash
kwl <namespace>
```

3. **Kubernetes logs of specific pod in namespace**

Code

```bash
function klp() {
  kubectl logs -n $1 $2
}
```

Call

```bash
klp <namespace> <pod-name>
```
