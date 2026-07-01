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

See `PLAN.md` for the design rationale and the Windows→Linux mapping.

## Layout

```
llama.cpp/
├── bootstrap.sh            # install prebuilt Vulkan llama.cpp into ./vendor
├── download-model.sh       # fetch GGUF(s) from HuggingFace into $LLAMA_MODELS_DIR
├── server.sh               # start llama-server (router or single model)
├── config.env.example      # copy to config.env and edit            [committed]
├── config.env              # your real values                       [gitignored]
├── models.list             # HuggingFace download manifest          [committed]
├── presets/
│   ├── models.example.ini  # router preset template                 [committed]
│   └── models.ini          # your real preset                       [gitignored]
├── vendor/                 # extracted binaries                     [gitignored]
└── cache/                  # downloaded tarballs                    [gitignored]
```

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

> Updating later: bump `LLAMA_VERSION` in `config.env`, then
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

## Configuration (`config.env`)

| Variable | Meaning |
|----------|---------|
| `LLAMA_VERSION` | release tag (e.g. `b9827`) or `latest` |
| `LLAMA_MODELS_DIR` | model storage **outside** the repo |
| `LLAMA_HOST` / `LLAMA_PORT` | server bind address (default `127.0.0.1:8081`) |
| `LLAMA_PRESET` | router preset path, relative to `llama.cpp/` |
| `LLAMA_MODELS_MAX` | max simultaneously loaded models in router mode |
| `LLAMA_NGL` / `LLAMA_CTX` / `LLAMA_KV` | single-model defaults |
| `HF_TOKEN` | optional, for gated/private HuggingFace downloads |

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

`vendor/`, `cache/`, `config.env`, `presets/models.ini`, and any `*.gguf` under
`llama.cpp/`. Models live outside the repo entirely and are never tracked. Only
scripts, `*.example` templates, `models.list`, and `presets/models.example.ini`
are committed.

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
