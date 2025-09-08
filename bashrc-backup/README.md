# Bashrc Backup

List of useful aliases and functions for bash shell.

# 📜Table of Contents

- [Bashrc Backup](#bashrc-backup)
- [📜Table of Contents](#table-of-contents)
  - [🔥Spotlight](#spotlight)
  - [🏷️Aliases](#️aliases)
    - [Base](#base)
    - [Git](#git)
  - [🔧Functions](#functions)
    - [Kubernetes Logs](#kubernetes-logs)
  - [Installation](#installation)
    - [Dependencies](#dependencies)
    - [Codex configuration](#codex-configuration)

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
- `alias gp1='git pull'`
- `alias gac='git add . && git commit -m'`
- `alias gp2='git push'`
- `alias gco='git checkout'`
- `alias gcob='git switch -c'`

See further aliases [here](./.bashrc-aliases).

## 🔧[Functions](#functions)

### Kubernetes Logs

1. **Watching alias commands**

Code

```bash
watching() {
    check_args 1 "watching <bashrc_alias>" "watching kgc" "$@" || return $?

    alias_command=$(alias "$1" | sed "s/^alias $1='//;s/'.*$//")

    if [ -z "$alias_command" ]; then
        echo "Alias '$1' not found in .bashrc!"
        return 1
    fi

    watch "$alias_command"
}
```

Usage

```bash
watching <bashrc_alias>
```

2. **Restarting Statefulsets or Deployments in a specific Namespace**

Code

```bash
function restarting() {
  check_args 2 "restarting <statefulsets/deployments> <namespace>" "restarting statefulset monitoring" "$@" || return $?

  local type="$1"
  local namespace="$2"

  entities=$(kubectl get "$type" -n "$namespace" --no-headers -o custom-columns=":metadata.name" | grep '^c4-.*-backend$')
  if [ -z "$entities" ]; then
    echo "No '$type' found for namespace '$namespace'."
    return 1
  fi

  for entity in $entities; do
    echo -e "\nRestart '$type' '$entity' in namespace '$namespace'"
    kubectl rollout restart "$type" "$entity" -n "$namespace"
    kubectl rollout status "$type" "$entity" -n "$namespace"
  done
}
```

Usage

```bash
restarting <statefulsets/deployments> <namespace>
```

See further functions [here](./.bashrc-functions).

## Installation

To use this script, first clone the repository:

```
git clone git@github.com:timlohse1104/tooling.git
```

Navigate to the `bashrc-backup` directory and run the installation script:

```bash
bash install.bash
```

### Dependencies

The alias `localcoder` requires the following dependencies:

- [codex](https://github.com/openai/codex)
- [ollama](https://ollama.com)
  - [gpt-oss:20b](https://ollama.com/library/gpt-oss)

See shortcut in [tilloh-homelab](https://github.com/timlohse1104/homelab).

### Codex configuration

Copy the [config.toml](./codex/config.toml) to `~/.codex/config.toml`.

Make sure to export `MISTRAL_API_KEY` in the terminal session.

This will provide all necessary prerequisites to run `mistralcoder` alias.