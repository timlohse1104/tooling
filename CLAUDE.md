# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

This is a documentation and tooling collection repository containing:
- A curated list of useful developer tools and services (README.md)
- Bash shell configuration backups with aliases and functions (bashrc-backup/)

## Structure

```
tooling/
├── README.md              # Curated list of developer tools/services
└── bashrc-backup/         # Bash configuration files
    ├── .bashrc            # Main bashrc with custom PS1 and file loading
    ├── .bashrc-aliases    # Shell aliases (git, kubectl, aws, claude)
    ├── .bashrc-functions  # Shell functions (kubernetes helpers)
    ├── install.bash       # Installation script
    └── codex/
        └── config.toml    # Codex CLI configuration for Mistral
```

## Installation

To install the bash configuration:

```bash
cd bashrc-backup
bash install.bash
```

This copies aliases/functions to home directory and appends custom bashrc settings.

## Key Aliases

- `aliases` - View all aliases
- `functions` - View all functions
- `normalclaude` / `openclaude` - Claude CLI with different settings
- `mistralcoder` - Codex with Mistral profile (requires `MISTRAL_API_KEY`)
- `localcoder` - Codex with local Ollama model

## Key Functions

- `switch <namespace>` - Switch kubernetes namespace
- `whereami` - Show current kubernetes context
- `watching <alias>` - Watch an alias command
- `serve <pod> <flags>` - Serve with pino-pretty output
- `kex <pod>` - Exec into a pod
- `klp <pod>` - Pod logs with pino-pretty
