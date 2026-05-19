# AGENTS.md

## Repository purpose

A personal tooling collection: curated developer tool references (`README.md`), bash config backups, OpenCode config backup, Claude config backup, and a fresh-Linux bootstrap guide.

No build system, no tests, no CI. All content is documentation and shell scripts.

## Structure

```
tooling/
├── README.md                        # Curated tool/service link list
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

- `bashrc-backup/install.bash` deletes the `# CUSTOM START` … `# CUSTOM END` block from `~/.bashrc`, appends the new block at the end, then calls `exec bash -l` to reload the shell.
- `opencode-backup/install.sh` copies `opencode.jsonc` to `~/.config/opencode/opencode.jsonc` (creates dir if needed).
- `claude-backup/install.sh` copies `settings.json`, `settings.local.json`, `mcp.json`, `commands/`, and `skills/` into `~/.claude/`. Note: `settings.local.json` is in `.gitignore` and won't be present in a fresh clone — the script will fail on that step; ignore or create an empty file first.

## Key aliases (after install)

| Alias | Expands to |
|-------|-----------|
| `oc` | `opencode` |
| `g` / `gs` / `gp1` / `gp2` | `git` / `git status` / `git pull` / `git push` |
| `gac 'msg'` | `git add . && git commit -m 'msg'` |
| `gcob <branch>` | `git switch -c <branch>` |
| `gl` | fancy graph git log |
| `c` / `h` | `clear` / `history` |
| `k` | `kubectl` |
| `kg` / `kl` / `kp` | `kubectl get pod` / `kubectl logs` / `kubectl port-forward` |
| `kdepl` / `kstate` | `kubectl get deployment` / `kubectl get statefulset` |
| `ksvc` / `ks` / `kexs` | `kubectl get svc/secrets/externalsecrets` |
| `kpv` / `kpvc` | `kubectl get pv/pvc` |
| `kr` / `krs` | `kubectl rollout restart deployment/statefulset` |
| `goprod` / `gotest` | `kubectx` to prod / test EKS cluster |
| `gobastion` | exec into documentdb-client pod in alfresco namespace |
| `flux1` / `flux2` | reconcile flux-system source / apps kustomization |
| `awslogin` | `aws sso login --profile c4-sso` |

## Key functions (after install)

| Function | Purpose |
|----------|---------|
| `switch <ns>` | Set current kubectl namespace |
| `whereami` | Show kubectx + current cluster/namespace |
| `watching <alias>` | `watch` the command behind a shell alias |
| `kex <pod>` | `kubectl exec -it <pod> -- sh` |
| `kd <type> <name>` | `kubectl describe <type> <name>` |
| `klp <pod>` | Pod logs piped through `pino-pretty@13.0.0` |
| `kwo <ns>` | Watch pods in namespace, filtering out `c4-*` |
| `serve <app> <flags>` | `nx serve` piped through `pino-pretty@13.0.0` |
| `restarting <type> <ns>` | Restart all `c4-*-backend` deployments/statefulsets in a namespace |
| `kdel <type> <name>` | Delete a k8s entity with confirmation prompt |
| `delete_with_status <ns>` | Delete pods with `ContainerStatusUnknown` in a namespace |

## OpenCode config notes

- Default model: `Qwen3.6-27B-IQ4_XS-mtp.gguf` (local llama.cpp at `172.30.48.1:8081`)
- Additional local models: `Qwen3.6-35B-A3B-MTP-IQ4_XS.gguf`, `gemma-4-26B-A4B-it-UD-Q4_K_XL.gguf` (llama.cpp); `qwen3.6-35b-a3b` (LM Studio at `192.168.1.169:1234`)
- Enabled providers: `lmstudio`, `llama.cpp`, `anthropic`
- Plugin: `opencode-claude-auth@latest`; `share: disabled`
- Read permission: `.env` and `.env.*` denied; `.env.example` / `.env.default` allowed
- MCP servers: `atlassian` (remote OAuth at `https://mcp.atlassian.com/v1/mcp`) and `playwright` (local via `npx @playwright/mcp@latest`)
- Many read-only kubectl, gh, aws, helm, flux, git, docker commands are pre-allowed (no prompt)

## Claude Code config notes

- MCP server: `chrome-devtools` (local via `npx chrome-devtools-mcp@latest`)
- Custom commands: `claude-backup/.claude/commands/commit-push.md`
- Skills: `c4-devops-ticket` (Jira ticket creation for DO project)

## Conventions

- This repo is a dotfiles/config backup, not a software project. Do not add build tooling or tests.
- `.gitignore` excludes `.claude/settings.local.json` and `.playwright-mcp`.
- Fresh machine setup order: SSH → clone repo → `bashrc-backup/install.bash` → Claude Code → `claude-backup/install.sh` → `opencode-backup/install.sh` → authenticate MCPs.
