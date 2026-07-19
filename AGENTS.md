# AGENTS.md

## Repository purpose

A personal tooling collection: curated developer tool references (`README.md`), bash config backups, OpenCode config backup, Claude config backup, and a fresh-Linux bootstrap guide.

No build system, no tests, no CI. All content is documentation and shell scripts.

## Structure

```
tooling/
├── README.md                        # Curated tool/service link list
├── visualize-uocr.py                # Render Unlimited-OCR grounding output as HTML
├── bashrc-backup/                   # Bash config to deploy to ~
│   ├── .bashrc                      # PS1 + sources aliases/functions
│   ├── .bashrc-aliases              # All shell aliases
│   ├── .bashrc-functions            # All shell functions
│   └── install.bash                 # Deploys to ~; replaces CUSTOM block
├── opencode-backup/
│   ├── opencode.jsonc               # OpenCode global config
│   ├── agents/                      # OpenCode primary/subagent markdown defs
│   │   └── research.md                # Read-only recon/research primary agent
│   └── install.sh                   # Copies config + agents/ to ~/.config/opencode/
├── claude-backup/
│   ├── .claude/                     # settings.json, mcp.json, commands/, skills/
│   └── install.sh                   # Copies to ~/.claude/
├── llama.cpp/                       # Local LLM inference (prebuilt Vulkan llama.cpp)
│   ├── bootstrap.sh                 # Fetch+extract prebuilt Vulkan release into vendor/
│   ├── download-model.sh            # Pull GGUF(s) from HuggingFace to $LLAMA_MODELS_DIR
│   ├── server.sh                    # Start llama-server (router or single model)
│   ├── config.env.example           # Paths/version/port (copy to config.env)
│   ├── models.list                  # HuggingFace download manifest
│   ├── presets/models.example.ini   # Router preset template
│   ├── PLAN.md / README.md          # Design + usage
│   └── vendor/ cache/               # Binaries + downloads (gitignored)
└── fresh_linux/debian-based/
    └── bootstrap-guide.md           # New machine setup checklist
```

## Install commands

| What | Command |
|------|---------|
| Bash aliases + functions | `cd bashrc-backup && bash install.bash` |
| OpenCode config | `cd opencode-backup && bash install.sh` |
| Claude Code config | `cd claude-backup && bash install.sh` |
| Local llama.cpp (Vulkan) | `cd llama.cpp && cp config.env.example config.env && bash bootstrap.sh` |

- `bashrc-backup/install.bash` deletes the `# CUSTOM START` … `# CUSTOM END` block from `~/.bashrc`, appends the new block at the end, then calls `exec bash -l` to reload the shell.
- `opencode-backup/install.sh` copies `opencode.jsonc` to `~/.config/opencode/opencode.jsonc` and any `agents/*.md` to `~/.config/opencode/agents/` (creates dirs if needed).
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

- No global default `model` is pinned in `opencode.jsonc` (pick per session).
- Two llama.cpp providers: `lieselotte` (local, `127.0.0.1:8081`) and `hermine` (remote, `hermine:8081`). Model IDs are bare aliases without the `.gguf` suffix.
- `lieselotte` models: `Qwen3.6-27B`, `Qwen3.6-35B-A3B`, `gemma-4-26B-A4B`, `ornith-1.0-9b`, `ornith-1.0-35b`, `Qwen-AgentWorld-35B-A3B`, `gemma-4-31B`. `hermine` models: `Qwen3.6-27B`, `gemma-4-31B`.
- Ornith-1.0 (DeepReinforce, MIT, agentic coding): 9B dense Q8_0 @ 262k ctx full-VRAM on the 7900 XTX; 35B MoE Q4_K_M @ 32k ctx tight-VRAM. Both use `--jinja` for reasoning/tool-calling.
- Qwen-AgentWorld-35B-A3B (Qwen, Apache-2.0, language world model): 35B-A3B MoE (arch `qwen35moe`, base Qwen3.5-35B-A3B) that simulates 7 agent environments (MCP/Search/Terminal/SWE/Android/Web/OS) via long CoT. Hybrid attention (10×(3× Gated-DeltaNet → 1× Gated-Attention)) means only ~10 of 40 layers carry a growing KV-cache, so long contexts are cheap on VRAM. `UD-IQ4_XS` (17.8 GB) full-GPU on the 7900 XTX (`device = Vulkan0`); `q8_0` KV fits the native 262k ctx (drop to 131072 if OOM). Thinking mode on by default → `jinja = true`. Vendor sampling: `temp 0.6`, `top-p 0.95`, `top-k 20`.
- Gemma 4 31B (Google/unsloth, Apache-2.0, dense QAT VLM): dense 31B (arch `gemma4`, 60 layers, native 256K ctx). Hybrid attention interleaves local sliding-window (1024) layers with periodic global layers (unified K/V + Proportional RoPE), so the growing KV-cache lives only in the few global layers → long contexts are cheap on VRAM. Quantization-aware-trained `UD-Q4_K_XL` (17.3 GB) keeps near-bf16 quality and fits the 24 GB 7900 XTX (`device = Vulkan0`) alongside the ~280 MB MTP drafter `mtp-gemma-4-31B-it.gguf`. MTP speculative decoding is wired via `spec-type = draft-mtp` + `model-draft = …/mtp-gemma-4-31B-it.gguf` + `spec-draft-n-max = 4` (lossless — the target verifies every drafted token). `ctx-size = 131072` in the local preset (native max 262144; raise if VRAM allows, drop/keep q8_0 KV if OOM). Text+Image via optional `mmproj = …/mmproj-F16.gguf`. Vendor sampling: `temp 1.0`, `top-p 0.95`, `top-k 64`; thinking is opt-in via a `<|think|>` token → `jinja = true`.
- Unlimited-OCR (Baidu, MIT, VLM): 3B DeepSeek-OCR-architecture model for one-shot long-horizon document parsing. Needs both `Unlimited-OCR-Q4_K_M.gguf` and `mmproj-Unlimited-OCR-F16.gguf` (preset key `mmproj = …`). Upstream support via PR #17400 (merged 2026-03-25), included in b9827. Prompts: `OCR`, `OCR markdown`, `<|grounding|>OCR` (with bboxes). Do NOT set `chat-template = deepseek-ocr` on the server.
- Enabled providers: `lieselotte`, `hermine`, `anthropic`, `openrouter`
- `openrouter` is the built-in OpenRouter provider (models preloaded from Models.dev); its API key is read from the `OPENROUTER_API_KEY` env var via `"apiKey": "{env:OPENROUTER_API_KEY}"` instead of `/connect`
- Plugin: `opencode-claude-auth@latest`; `share: disabled`
- Read permission: `.env` and `.env.*` denied; `.env.example` / `.env.default` allowed
- MCP servers: `atlassian` (remote OAuth at `https://mcp.atlassian.com/v1/mcp`) and `playwright` (local via `npx @playwright/mcp@latest`)
- Many read-only kubectl, gh, aws, helm, flux, git, docker commands are pre-allowed (no prompt)

## Claude Code config notes

- MCP server: `chrome-devtools` (local via `npx chrome-devtools-mcp@latest`)
- Custom commands: `claude-backup/.claude/commands/commit-push.md`
- Skills: `c4-devops-ticket` (Jira ticket creation for DO project)

## llama.cpp config notes

- Linux/Pop!_OS adaptation of `countzero/windows_llama.cpp`; **Vulkan** backend, **prebuilt** binaries (no compiler/conda).
- Scope: run already-built GGUF models only (no quantization/conversion).
- `bootstrap.sh` downloads `llama-<tag>-bin-ubuntu-vulkan-<arch>.tar.gz` into `vendor/` (idempotent, `--force` to reinstall).
- `download-model.sh` pulls GGUFs to `$LLAMA_MODELS_DIR` (default `~/.local/share/llama.cpp/models`, outside the repo); prefers `hf`/`huggingface-cli`, falls back to `curl`; manifest `models.list`.
- `server.sh`: router mode (default, `presets/models.ini`) or single model; serves OpenAI-compatible API at `LLAMA_HOST:LLAMA_PORT` (default `127.0.0.1:8081`).
- `LLAMA_VERSION` defaults to `latest`. `server.sh`/`server.ps1` auto-run `bootstrap.*` before serving to pick up new releases, throttled by a `vendor/.last-auto-check` marker (`LLAMA_UPDATE_CHECK_INTERVAL`, default 3600s) so repeated restarts don't hit GitHub's API. `LLAMA_AUTO_UPDATE=0` disables it (offline use); a failed check falls back to the already-installed build instead of hard-failing.
- Config in `config.env` (gitignored; copy from `config.env.example`).
- Models are **never** committed: `.gitignore` excludes `llama.cpp/{vendor,cache}/`, `config.env`, `presets/models.ini`, and `**/*.gguf`.
- OpenCode: the local `lieselotte` provider `baseURL` is `http://127.0.0.1:8081/v1`; the remote `hermine` provider points at `http://hermine:8081/v1`.
- Skill `.claude/skills/llama-preset/` (`scripts/recommend.sh`): generates/updates a `presets/models.ini` `[section]` tuned both to the detected hardware (GPU/VRAM via `llama-server --list-devices`, autosizing via `llama-fit-params`, iGPU deprioritized) and to best quality/speed for **agentic** use — `cache-type-k = q8_0` (floor, K is quant-sensitive), `cache-type-v = q4_0` (floor, V tolerates more), `parallel = 1`, `cache-reuse`, `reasoning-format = auto`, auto-wired lossless MTP speculative decoding when the model has one (self-speculative HF "-MTP-" repo or a sibling `mtp-*.gguf`). Sampling temp prefers the model card's lower/more deterministic option; `temp = 0` is refused unless `--zero-temp-ok` confirms the card actually recommends greedy decoding. Every agentic key is gated on the **installed** `llama-server --help`/`--version` actually supporting it (never hardcoded — always re-probes, so upgrading llama.cpp unlocks better defaults automatically), with a graceful fallback + note on older builds. OCR/document-parsing models (section name matches "ocr") keep the old conservative defaults and are exempt from the zero-temp guard. Re-running on an already-configured model re-tunes it and prints an OPTIMIZATION DIFF. Resolves the HuggingFace model card from `models.list` (`--hf-url`) and folds in vendor best practices via `--extra KEY=VALUE` — hardware/agentic-owned keys (`device`, `n-gpu-layers`, `n-cpu-moe`, `ctx-size`, `flash-attn`, `cache-type-k/v`, `jinja`, `parallel`, `cache-reuse`, `reasoning-format`, `spec-type`, `model-draft`, `spec-draft-n-max`) are never overridden.

## Conventions

- This repo is a dotfiles/config backup, not a software project. Do not add build tooling or tests.
- `.gitignore` excludes `.claude/settings.local.json`, `.playwright-mcp`, and the llama.cpp `vendor/`, `cache/`, `config.env`, `presets/models.ini`, and `*.gguf`.
- Fresh machine setup order: SSH → clone repo → `bashrc-backup/install.bash` → Claude Code → `claude-backup/install.sh` → `opencode-backup/install.sh` → authenticate MCPs → (optional) `llama.cpp/bootstrap.sh`.
