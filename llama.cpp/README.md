# llama.cpp on Pop!_OS / Debian-based Linux

Config-driven setup to run **already-built GGUF models** with llama.cpp on the
**Vulkan** backend. Linux adaptation of
[countzero/windows_llama.cpp](https://github.com/countzero/windows_llama.cpp).

- No compiler / CMake / conda — `bootstrap.sh` downloads the official **prebuilt
  Vulkan** release tarball from llama.cpp.
- Models are pulled from HuggingFace into a directory **outside this repo**
  (`$LLAMA_MODELS_DIR`) and are **never committed** to git.
- Multi-model **router mode** via an INI preset (same format as upstream), so one
  endpoint serves several models on demand.
- **Windows PowerShell** is supported too: `bootstrap.ps1` / `download-model.ps1`
  / `server.ps1` are one-to-one equivalents of the `.sh` scripts. On Windows they
  target **NVIDIA/CUDA** (the Windows box has an RTX 4090); the `.sh` scripts stay
  on **Vulkan** (the Linux box has an AMD RX 7900 XTX). See the
  [Windows (PowerShell)](#windows-powershell) section.

See `PLAN.md` for the design rationale and the Windows→Linux mapping.

## Layout

```
llama.cpp/
├── bootstrap.sh            # Linux (Vulkan):   install prebuilt llama.cpp into ./vendor
├── download-model.sh       # Linux:            fetch GGUF(s) from HuggingFace into $LLAMA_MODELS_DIR
├── server.sh               # Linux:            start llama-server (router or single model)
├── bootstrap.ps1           # Windows (CUDA):   install prebuilt llama.cpp + cudart into .\vendor
├── download-model.ps1      # Windows:          fetch GGUF(s) from HuggingFace into $LLAMA_MODELS_DIR
├── server.ps1              # Windows:          start llama-server (router or single model)
├── config.env.example      # Linux:   copy to config.env and edit    [committed]
├── config.env              # Linux:   your real values               [gitignored]
├── config.ps1.example      # Windows: copy to config.ps1 and edit    [committed]
├── config.ps1              # Windows: your real values               [gitignored]
├── models.list             # HuggingFace download manifest (shared)  [committed]
├── presets/
│   ├── models.example.ini  # router preset template (shared)         [committed]
│   └── models.ini          # your real preset                        [gitignored]
├── vendor/                 # extracted binaries                      [gitignored]
└── cache/                  # downloaded archives                     [gitignored]
```

The `.sh` scripts (Linux) and `.ps1` scripts (Windows PowerShell) are functional
equivalents and share `models.list`, `presets/`, `vendor/`, and `cache/`. They
differ in two ways: the config file (`config.env` for bash vs `config.ps1` for
PowerShell) and the compute backend they install — `.sh` fetches the **Vulkan**
build, `.ps1` fetches the **CUDA** build plus its cudart runtime.

Models live under `$LLAMA_MODELS_DIR` (default `~/.local/share/llama.cpp/models`),
**not** inside this repo.

## Quick start

```sh
cd ~/tooling/llama.cpp

cp config.env.example config.env          # set version / port / paths
bash bootstrap.sh                         # fetch + verify Vulkan llama.cpp

# choose & download a model:
$EDITOR models.list                       # uncomment/add your HF models
bash download-model.sh --all              # or: ./download-model.sh <repo> <file> [subdir]

# configure serving:
cp presets/models.example.ini presets/models.ini
sed -i "s|/home/USER|$HOME|g" presets/models.ini

bash server.sh                            # router @ http://127.0.0.1:8081
```

## Step-by-step bootstrap

Full sequence from a freshly installed Debian-based system (Pop!_OS) to a running
server. The broader OS setup (SSH key, GitHub) lives in
`../fresh_linux/debian-based/bootstrap-guide.md`.

**1. System prerequisites**
```sh
sudo apt update && sudo apt install -y git curl
```

**2. Clone the tooling repo** (skip if already cloned)
```sh
git clone git@github.com:timlohse1104/tooling.git ~/tooling
cd ~/tooling/llama.cpp
```

**3. Create your local config**
```sh
cp config.env.example config.env
$EDITOR config.env        # check LLAMA_VERSION, LLAMA_PORT, LLAMA_MODELS_DIR
```

**4. Install llama.cpp** (asks for `sudo` to install APT runtime deps)
```sh
bash bootstrap.sh
```
Expected at the end: a printed `llama-server` version and `Vulkan: OK (GPU visible)`.
If you see `WARNING: ... no usable GPU`, it will still run on CPU — fix GPU drivers
later (see Troubleshooting).

**5. Pick and download a model**
```sh
$EDITOR models.list                 # uncomment a line or add: repo_id | file.gguf | subdir
bash download-model.sh --all        # downloads into $LLAMA_MODELS_DIR (outside the repo)
bash server.sh --list               # confirm the .gguf is present
```
Single ad-hoc download instead of the manifest:
```sh
bash download-model.sh bartowski/gemma-2-9b-it-GGUF gemma-2-9b-it-IQ4_XS.gguf gemma-2-9b-it
```

**6. Configure which models to serve**
```sh
cp presets/models.example.ini presets/models.ini
sed -i "s|/home/USER|$HOME|g" presets/models.ini
$EDITOR presets/models.ini          # keep only the models you downloaded; fix paths/ctx-size
```

**7. Start the server**
```sh
bash server.sh                      # router @ http://127.0.0.1:8081
```

**8. Verify the endpoint** (from a second terminal)
```sh
curl http://127.0.0.1:8081/v1/models
curl http://127.0.0.1:8081/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"<section-header-from-models.ini>","messages":[{"role":"user","content":"Say hi"}]}'
```

**9. (Optional) Point OpenCode at it** — in `~/.config/opencode/opencode.jsonc`
set the `llama.cpp` provider `baseURL` to `http://127.0.0.1:8081/v1`.

**10. (Optional) Run in the background**
```sh
nohup bash server.sh > ~/llama-server.log 2>&1 &   # detach; stop with: pkill -f llama-server
```

> Updating later: with the default `LLAMA_VERSION="latest"`, `server.sh` checks
> for a newer release on every start (throttled, see "Auto-update on server
> start" below) — no manual step needed. To force an immediate update outside
> that throttle window, or if you're pinned to a specific tag, run
> `bash bootstrap.sh --force`.

## Scripts

### `bootstrap.sh [--force]`
Installs the prebuilt Vulkan release set by `LLAMA_VERSION`:
1. installs APT runtime deps (`libvulkan1`, `mesa-vulkan-drivers`, `vulkan-tools`,
   `libgomp1`, `libcurl4`, `curl`, `jq`, `tar`) — only the missing ones;
2. resolves the release tag (`latest` → GitHub API);
3. downloads `llama-<tag>-bin-ubuntu-vulkan-<arch>.tar.gz` into `cache/`;
4. extracts it to `vendor/llama.cpp/`;
5. verifies `llama-server --version` and `vulkaninfo --summary`.

Re-running is idempotent (a version marker skips re-download; `--force` overrides).

### `download-model.sh`
```sh
./download-model.sh <repo_id> <filename> [dest_subdir]   # one file
./download-model.sh --all                                # everything in models.list
./download-model.sh --list                               # show manifest
```
Uses `hf` / `huggingface-cli` when available (resume, auth), otherwise `curl`
against `https://huggingface.co/<repo>/resolve/main/<file>`. Existing files are
skipped. Gated models: set `HF_TOKEN` in `config.env` or run `hf auth login`.

### `server.sh`
```sh
./server.sh                       # router mode (multi-model) via $LLAMA_PRESET
./server.sh <model.gguf> [args]   # single model; extra args pass through
./server.sh --list                # list GGUF files under $LLAMA_MODELS_DIR
```
Single-model mode auto-detects physical core count and a sibling `mmproj.*` file.
Heavy per-model tuning (`n-cpu-moe`, `cache-type-*`, sampling, speculative
decoding, …) belongs in the preset INI.

## Windows (PowerShell)

The `.ps1` scripts mirror the `.sh` scripts one-to-one, but target **NVIDIA/CUDA**
(the Windows box has an RTX 4090). `bootstrap.ps1` fetches the prebuilt Windows
CUDA zip (`llama-<tag>-bin-win-cuda-<ver>-x64.zip`) **and** the matching CUDA
runtime (`cudart-llama-bin-win-cuda-<ver>-x64.zip`), extracting the cudart DLLs
next to the binaries. No compiler/CMake/conda. (The `.sh` scripts stay on Vulkan
for the Linux/AMD box.)

Requirements: Windows 10/11 x64, PowerShell 5.1+ (or PowerShell 7), a current
**NVIDIA driver** (new enough for the chosen CUDA version — 12.4 is the safe
default, 13.3 needs a recent driver), and the
[Microsoft Visual C++ Redistributable (x64)](https://aka.ms/vs/17/release/vc_redist.x64.exe).

```powershell
cd $HOME\tooling\llama.cpp

# If scripts are blocked, allow local scripts for this session:
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass

Copy-Item config.ps1.example config.ps1     # set version / port / paths / $LLAMA_CUDA
.\bootstrap.ps1                              # fetch CUDA build + cudart, then verify

# choose & download a model (edit models.list, then):
.\download-model.ps1 -All                    # or: .\download-model.ps1 <repo> <file> [subdir]

# configure serving — copy the preset and rewrite the placeholder paths to your
# models dir (llama.cpp accepts forward slashes on Windows):
$dst = ($env:LOCALAPPDATA -replace '\\','/') + '/llama.cpp/models'
(Get-Content presets\models.example.ini) `
    -replace '/home/USER/.local/share/llama.cpp/models', $dst |
    Set-Content presets\models.ini

.\server.ps1                                 # router @ http://127.0.0.1:8081
```

Script reference (identical semantics to the `.sh` versions):

| Windows | Purpose |
|---------|---------|
| `.\bootstrap.ps1 [-Force]` | install/refresh the prebuilt Windows **CUDA** release (+ cudart runtime) into `.\vendor` |
| `.\download-model.ps1 <repo> <file> [subdir]` / `-All` / `-List` | pull GGUF(s) into `$LLAMA_MODELS_DIR` |
| `.\server.ps1` / `.\server.ps1 <model.gguf> [args]` / `.\server.ps1 -List` | router mode / single model / list models |

Notes:
- Config lives in `config.ps1` (PowerShell variables), the counterpart of
  `config.env`. `$LLAMA_CUDA` selects the CUDA build (`12.4` or `13.3`); default
  model dir is `%LOCALAPPDATA%\llama.cpp\models`.
- The router preset and its `n-gpu-layers` / `cache-type-*` / `flash-attn` keys
  are backend-agnostic and work unchanged on CUDA (the `7900 XTX` mentions in
  `models.example.ini` are only comments).
- Downloads prefer `hf`/`huggingface-cli` if installed, else `curl.exe`
  (bundled with Windows 10+), else `Invoke-WebRequest`.
- Binaries extract to `vendor\llama.cpp\` (cudart DLLs beside `llama-server.exe`);
  a `vendor\.llama-version-win` marker (`<tag>-cuda-<ver>-x64`) makes re-runs
  idempotent. `-Force` reinstalls; changing `$LLAMA_CUDA` also triggers a reinstall.
- If `llama-server.exe` fails to start with a missing-DLL error, install the
  VC++ Redistributable linked above.

## Configuration (`config.env` / `config.ps1`)

| Variable | Meaning |
|----------|---------|
| `LLAMA_VERSION` | `latest` (default, recommended) or a pinned release tag (e.g. `b9827`) |
| `LLAMA_BACKEND` | `vulkan` (bash/Linux) or `cuda` (PowerShell/Windows) |
| `LLAMA_CUDA` | Windows only: CUDA build to fetch (`12.4` or `13.3`) |
| `LLAMA_MODELS_DIR` | model storage **outside** the repo |
| `LLAMA_HOST` / `LLAMA_PORT` | server bind address (default `127.0.0.1:8081`) |
| `LLAMA_PRESET` | router preset path, relative to `llama.cpp/` |
| `LLAMA_MODELS_MAX` | max simultaneously loaded models in router mode |
| `LLAMA_NGL` / `LLAMA_CTX` / `LLAMA_KV` | single-model defaults |
| `LLAMA_AUTO_UPDATE` | `1` (default) auto-runs bootstrap before serving; `0` disables (offline use) |
| `LLAMA_UPDATE_CHECK_INTERVAL` | seconds between auto-update checks (default `3600`); `0` = check on every start |
| `HF_TOKEN` | optional, for gated/private HuggingFace downloads |

## Auto-update on server start

With the default `LLAMA_VERSION="latest"`, `server.sh` / `server.ps1` run
`bootstrap.sh` / `bootstrap.ps1` before serving to pick up newer releases
automatically. `bootstrap.*` is idempotent (skips the download if the
resolved tag is already installed), so this is cheap once up to date. A local
marker (`vendor/.last-auto-check`) throttles the check to once per
`LLAMA_UPDATE_CHECK_INTERVAL` seconds, so restarting the server repeatedly
doesn't hammer GitHub's API (rate limits) or require network on every start.
If the check fails (offline, rate-limited), serving continues with whatever
build is already installed — it only hard-fails if no build is installed at
all. Set `LLAMA_AUTO_UPDATE=0` to disable entirely, or keep a pinned
`LLAMA_VERSION` tag instead of `latest` if you want fully manual updates
(`bash bootstrap.sh --force`).

## Model preset (`presets/*.ini`)

Each `[section]` is a model; the header is the name clients send in the OpenAI
`"model"` field. Keys are `llama-server` flags without `--`. Paths must be
absolute and point inside `$LLAMA_MODELS_DIR`. The committed `models.example.ini`
uses `/home/USER` placeholders; replace them when you copy it to `models.ini`.

## OpenCode integration

The `llama.cpp` provider in `opencode-backup/opencode.jsonc` currently points at
`http://172.30.48.1:8081/v1` (a WSL→Windows-host gateway IP). On native Pop!_OS,
change it to `http://127.0.0.1:8081/v1`. The port (`8081`) and model names here
are kept aligned with that config.

## What is gitignored

`vendor/`, `cache/`, `config.env`, `config.ps1`, `presets/models.ini`, and any
`*.gguf` under `llama.cpp/`. Models live outside the repo entirely and are never
tracked. Only scripts (`*.sh` + `*.ps1`), `*.example` templates, `models.list`,
and `presets/models.example.ini` are committed.

## Vision-language / OCR models (Unlimited-OCR)

`models.list` includes Baidu's **Unlimited-OCR** (3B VLM, DeepSeek-OCR
architecture). Vision-capable models need a separate **multimodal projector**
(`mmproj-*.gguf`) alongside the LM GGUF. The committed preset entry references
both:

```sh
bash download-model.sh --all     # pulls Unlimited-OCR-Q4_K_M.gguf + mmproj
bash server.sh                   # router serves model alias "Unlimited-OCR"
```

DeepSeek-OCR support is upstream since llama.cpp PR
[#17400](https://github.com/ggml-org/llama.cpp/pull/17400) (merged 2026-03-25);
release `b9827` (and later) Vulkan prebuilts contain it. Per the PR maintainer,
do **not** set `--chat-template deepseek-ocr` on the server — the embedded Jinja
template is used automatically.

Call it via the OpenAI-compatible API with a base64 `image_url` part:

```sh
IMG=$(base64 -w0 document.png)
curl http://127.0.0.1:8081/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "Unlimited-OCR",
    "temperature": 0,
    "messages": [{"role":"user","content":[
      {"type":"text","text":"<|grounding|>OCR markdown"},
      {"type":"image_url","image_url":{"url":"data:image/png;base64,'"$IMG"'"}}
    ]}]
  }'
```

Useful prompts:

| Prompt | Output |
|--------|--------|
| `OCR` | plain text only |
| `OCR markdown` | layout-aware Markdown |
| `<|grounding|>OCR` | text + `<|det|>… [x1,y1,x2,y2]<|/det|>` bounding boxes |
| `<|grounding|>OCR markdown` | Markdown with grounding boxes |

For one-shot CLI use without the router, `llama-mtmd-cli` works too:

```sh
./vendor/llama.cpp/llama-b9827/llama-mtmd-cli \
  -m ~/.local/share/llama.cpp/models/Unlimited-OCR/Unlimited-OCR-Q4_K_M.gguf \
  --mmproj ~/.local/share/llama.cpp/models/Unlimited-OCR/mmproj-Unlimited-OCR-F16.gguf \
  --image document.png -p "<|grounding|>OCR markdown" --temp 0
```

## Troubleshooting

- **`GLIBC_x.xx not found`** — the prebuilt is built on a newer Ubuntu than your
  Pop!_OS base. Upgrade the base or build llama.cpp from source (not covered here).
- **`vulkaninfo` shows no device** — install/repair GPU drivers; NVIDIA provides
  its own Vulkan ICD, AMD/Intel via `mesa-vulkan-drivers`. Without a GPU,
  llama.cpp falls back to CPU.
- **HTTP 401/403 on download** — gated model; set `HF_TOKEN` or `hf auth login`.
- **`error: unknown argument: --models-preset`** — your llama-server is too old;
  bump `LLAMA_VERSION` and re-run `bootstrap.sh --force`.

Windows (CUDA):
- **`cudart64_*.dll` / `cublas64_*.dll` not found`** — the cudart runtime is
  missing beside `llama-server.exe`; re-run `.\bootstrap.ps1 -Force`.
- **CUDA error / exe exits immediately** — the NVIDIA driver is too old for the
  chosen CUDA build. Set `$LLAMA_CUDA = "12.4"` in `config.ps1` (widest driver
  compatibility) and re-run `.\bootstrap.ps1 -Force`, or update the driver.
- **`nvidia-smi not found`** — no NVIDIA driver installed; the CUDA build needs
  one (there is no CPU fallback in the CUDA-only binary path for GPU ops).
- **VCRUNTIME140.dll missing** — install the VC++ x64 Redistributable
  ([link](https://aka.ms/vs/17/release/vc_redist.x64.exe)).
