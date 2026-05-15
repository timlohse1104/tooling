# AGENTS.md

## Repository purpose

A personal tooling collection: curated developer tool references (`README.md`), bash config backups, OpenCode config backup, Claude config backup, and a fresh-Linux bootstrap guide.

No build system, no tests, no CI. All content is documentation and shell scripts.

## Structure

```
tooling/
├── README.md                        # Curated tool/service link list
├── CLAUDE.md                        # Claude Code session guidance
├── bashrc-backup/                   # Bash config to deploy to ~
│   ├── .bashrc                      # PS1 + sources aliases/functions
│   ├── .bashrc-aliases              # All shell aliases
│   ├── .bashrc-functions            # All shell functions
│   └── install.bash                 # Deploys to ~; replaces CUSTOM block
├── opencode-backup/
│   ├── opencode.jsonc               # OpenCode global config
│   └── install.sh                   # Copies to ~/.config/opencode/
├── claude-backup/
│   ├── .claude/                     # settings.json, mcp.json, commands/, skills/
│   └── install.sh                   # Copies to ~/.claude/
└── fresh_linux/debian-based/
    └── bootstrap-guide.md           # New machine setup checklist
```

## Install commands

| What | Command |
|------|---------|
| Bash aliases + functions | `cd bashrc-backup && bash install.bash` |
| OpenCode config | `cd opencode-backup && bash install.sh` |
| Claude Code config | `cd claude-backup && bash install.sh` |

- `bashrc-backup/install.bash` replaces the `# CUSTOM START` … `# CUSTOM END` block in `~/.bashrc` and calls `exec bash -l` to reload the shell.
- `opencode-backup/install.sh` copies `opencode.jsonc` to `~/.config/opencode/opencode.jsonc`.
- `claude-backup/install.sh` copies settings, MCP config, commands, and skills into `~/.claude/`.

## Key aliases (after install)

| Alias | Expands to |
|-------|-----------|
| `oc` | `opencode` |
| `gac 'msg'` | `git add . && git commit -m 'msg'` |
| `gl` | fancy graph git log |
| `k` | `kubectl` |
| `goprod` / `gotest` | `kubectx` to prod / test EKS cluster |
| `kr` / `krs` | `kubectl rollout restart deployment/statefulset` |
| `awslogin` | `aws sso login --profile c4-sso` |

## Key functions (after install)

| Function | Purpose |
|----------|---------|
| `switch <ns>` | Set current kubectl namespace |
| `whereami` | Show kubectx + current cluster/namespace |
| `watching <alias>` | `watch` the command behind a shell alias |
| `kex <pod>` | `kubectl exec -it <pod> -- sh` |
| `klp <pod>` | Pod logs piped through `pino-pretty` |
| `serve <app> <flags>` | `nx serve` piped through `pino-pretty` |
| `restarting <type> <ns>` | Restart all `c4-*-backend` deployments/statefulsets in a namespace |
| `kdel <type> <name>` | Delete a k8s entity with confirmation prompt |
| `delete_with_status <ns>` | Delete pods with `ContainerStatusUnknown` in a namespace |

## OpenCode config notes

- Default model: `Qwen3.6-27B-IQ4_XS-mtp.gguf` (local llama.cpp at `172.30.48.1:8081`)
- Also configures LM Studio (`192.168.1.169:1234`) and Anthropic as enabled providers.
- Plugin: `opencode-claude-auth@latest`
- `.env` and `.env.*` files are denied by read permission rules (`.env.example` / `.env.default` are allowed).
- MCP servers configured: `atlassian` (remote OAuth) and `chrome` (local via `npx chrome-mcp`).

## Conventions

- This repo is a dotfiles/config backup, not a software project. Do not add build tooling or tests.
- The `bashrc-backup/README.md` documents the `ll` alias (`ls -alF`) which is not in `.bashrc-aliases` — it may exist in the system `.bashrc` only.
- `.gitignore` excludes `.claude/settings.local.json` and `.playwright-mcp`.
- Fresh machine setup order: SSH → clone repo → `bashrc-backup/install.bash` → Claude Code → `claude-backup/install.sh` → `opencode-backup/install.sh`.
