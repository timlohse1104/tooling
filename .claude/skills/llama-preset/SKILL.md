---
name: llama-preset
description: Erzeugt bzw. aktualisiert für ein in models.list/auf dem System vorhandenes Modell den passenden [section]-Eintrag in llama.cpp/presets/models.ini, abgestimmt auf die real verbaute Hardware (GPU/VRAM via Vulkan, CPU-Kerne, RAM) und Treiber. Triggert bei Anfragen wie "models.ini erstellen/anpassen", "llama.cpp Modell konfigurieren", "Preset für <Modell> generieren", "n-gpu-layers / n-cpu-moe / ctx-size für mein System bestimmen", "Modell an meine GPU anpassen". Nutzt `llama-server --list-devices` und `llama-fit-params` zum Autosizing. Use ONLY for the llama.cpp tooling in this repo, not for editing opencode/Claude config.
---

# llama-preset — hardware-tuned `models.ini` sections

Given a model name, produce the correct `llama-server` settings for **this**
machine and write them as a `[section]` in `llama.cpp/presets/models.ini`.

Settings are derived from what is actually installed:
- GPU(s), total/free VRAM and driver, via `llama-server --list-devices` (Vulkan).
- Autosized `n-gpu-layers` / `n-cpu-moe` / `ctx-size`, via `llama-fit-params`
  (the same `--fit` engine `llama-server` uses), with a transparent file-size
  heuristic as fallback.
- CPU physical cores and system RAM (for CPU-offload sizing).

The heavy lifting is in `scripts/recommend.sh` (deterministic). Your job is to
run it, sanity-check the result, merge it, and verify.

## Preconditions

1. llama.cpp is bootstrapped (`llama.cpp/vendor/.../llama-server` exists). If not:
   `cd llama.cpp && cp config.env.example config.env && bash bootstrap.sh`.
2. The target GGUF is downloaded into `$LLAMA_MODELS_DIR` (default
   `~/.local/share/llama.cpp/models`, outside the repo). If not, the model is
   typically listed in `llama.cpp/models.list` → `bash download-model.sh --all`
   (or a single `./download-model.sh <repo> <file> [subdir]`). The script errors
   out clearly if the file is missing — do **not** invent a path.

## Procedure

### 1. Identify the model
Accept a section name, a `.gguf` filename, or a full path. The section header in
`models.ini` equals the GGUF filename (e.g. `[Qwen3.6-27B-IQ4_XS-mtp.gguf]`),
matching the existing convention. If unsure which models exist:
`bash llama.cpp/server.sh --list`.

### 2. Inspect hardware + autosize (dry-run first)
```sh
bash .claude/skills/llama-preset/scripts/recommend.sh "<model>"
```
This prints the device table, model facts (size, MoE?, `n_layer`, `n_ctx_train`),
the chosen device, the raw `llama-fit-params` output, and a ready `[section]`
block. Useful flags:
- `--device Vulkan0` force a specific GPU (default: best **discrete** GPU; the
  script penalises integrated GPUs such as Intel UHD/Iris).
- `--ctx N` force context size (otherwise fit chooses, capped at `n_ctx_train`).
- `--margin MiB` VRAM headroom to leave free per device (default `1024`).
- `--list-devices` just print the parsed device table and exit.

### 3. Check the model card (vendor best practices)
Hardware tuning cannot know what the **publisher** recommends. Read the model
card and fold in only the settings that are NOT hardware-derived.

```sh
bash .claude/skills/llama-preset/scripts/recommend.sh "<model>" --hf-url
```
This resolves the HuggingFace `repo_id`(s) from `models.list` (matching by
filename or `dest_subdir`, so it still works when the local file was renamed)
and prints the model-card URL(s). Then **WebFetch** the `MATCH` URL (and, for a
re-quant repo like unsloth/bartowski, also the original base model it links to)
and extract publisher guidance, e.g.:
- **Sampling**: `temp`, `top-p`, `top-k`, `min-p`, `repeat-penalty`
  (e.g. Qwen3 recommends `temp 0.6, top-p 0.95, top-k 20`; "thinking" vs
  "non-thinking" presets often differ).
- **Chat template / prompt**: a required `--jinja`, a fixed `chat-template`, or a
  separate `chat-template-file` to download via `models.list`.
- **Long context**: RoPE/YaRN settings (`rope-scaling`, `rope-freq-base`,
  `yarn-*`) needed to go beyond the trained `n_ctx_train`.

If you cannot confirm a value from the card, do **not** set it.

### 4. Review before writing
Read the `# source` comment on each emitted key. Prefer values marked
`llama-fit-params`. Treat `heuristic:` values as a starting point and adjust
using the decision reference below. Confirm the device choice matches the
intended GPU (multi-GPU systems may list a discrete card **and** an iGPU).

### 5. Merge into the preset
Re-run with `--write` and pass the model-card findings as `--extra KEY=VALUE`
(repeatable). Hardware-owned keys always win: an `--extra` that collides with a
key the script tuned for this hardware is **refused** (reported on stderr), never
silently overridden — exactly the rule "only set what the hardware step did not
already set".
```sh
bash .claude/skills/llama-preset/scripts/recommend.sh "<model>" --write \
  --extra temp=0.6 --extra top-p=0.95 --extra top-k=20
```
`--write` is idempotent (replaces an existing same-named section, creates
`models.ini` from the example header if missing). You may instead apply the
printed block with the Edit tool — but **only** touch the one `[section]`; never
reformat or drop other models.

### 6. Verify
```sh
bash llama.cpp/server.sh --list          # confirm the GGUF is present
bash llama.cpp/server.sh                 # router mode; watch the load log
# in another shell:
curl http://127.0.0.1:8081/v1/models
```
If the server OOMs on the GPU, lower `n-gpu-layers`, raise `n-cpu-moe` (MoE), or
drop `ctx-size` / set `cache-type-k = q8_0` and re-verify.

### 7. Summarize
Report: model, chosen device + VRAM, final `n-gpu-layers` / `n-cpu-moe` /
`ctx-size` and their source, which vendor settings were added from the model
card (and any that were refused as hardware-owned), and whether `models.ini`
was written.

## Decision reference

Preset keys are `llama-server` long flags **without** the leading `--` (see
`llama-server --help`). Mapping facts → keys:

| Situation | Keys to set |
|-----------|-------------|
| Single discrete GPU, model fits VRAM | `device = <GPU>`, `n-gpu-layers = 999` |
| Model larger than VRAM (**dense**) | lower `n-gpu-layers` to the largest count that fits (fit-params computes it) |
| Model larger than VRAM (**MoE**, e.g. A3B/A4B) | keep `n-gpu-layers = 999`, push experts to CPU with `n-cpu-moe = N` (raise N = less VRAM, slower) |
| Discrete + integrated GPU present | pin `device = <discreteGPU>`; do **not** offload to the iGPU |
| True multi-GPU (2+ discrete) | `tensor-split = a,b` and/or `main-gpu`, `split-mode = layer` |
| VRAM tight on KV cache | `cache-type-k = q8_0`, `cache-type-v = q8_0`; shrink `ctx-size` |
| No usable GPU (Vulkan empty) | `n-gpu-layers = 0`; runs on CPU, set `threads` ≈ physical cores |
| Always | `flash-attn = auto`, `jinja = true` (needed for tool-calling/reasoning) |
| Vendor/model card (step 3) | sampling `temp`/`top-p`/`top-k`/`min-p`/`repeat-penalty`, `chat-template[-file]`, `rope-scaling`/`yarn-*` — via `--extra` |

Two classes of settings:
- **Hardware-owned** (the script tunes these to the machine): `device`,
  `n-gpu-layers`, `n-cpu-moe`, `ctx-size`, `flash-attn`, `cache-type-k/v`,
  `jinja`, plus `model`/`alias`. These are never overridden by `--extra`.
- **Vendor-owned** (from the model card, supplied via `--extra`): everything
  else, e.g. sampling and prompt-template keys. They only fill gaps the hardware
  step left open.

Notes:
- `n-gpu-layers = 999` means "all layers" and is clamped automatically.
- `ctx-size` must not exceed the model's `n_ctx_train` (the script caps it). If
  the vendor documents YaRN/RoPE to extend it, that is a deliberate override —
  raise `--ctx` explicitly rather than fighting the cap.
- `device` values come from `--list-devices` (e.g. `Vulkan0`), comma-separated
  for multiple.

## Safety / repo rules

- `presets/models.ini` is **gitignored** (machine-specific paths) — never commit
  it, and never commit `*.gguf`. Only `presets/models.example.ini` is tracked.
- Model paths must be **absolute** and point inside `$LLAMA_MODELS_DIR` (outside
  the repo).
- Edit exactly the one `[section]` you were asked about; leave others untouched.
- Never fabricate VRAM/layer numbers — if `llama-fit-params` output can't be
  parsed, say so and use the labelled heuristic, then verify by actually loading.
- Never copy a vendor setting you did not actually find on the model card, and
  never let a vendor `--extra` override a hardware-tuned key (the script refuses
  it; keep it that way).

## Files

- `scripts/recommend.sh` — probe hardware + autosize + look up the model card
  (`--hf-url`) + merge one `models.ini` section, accepting vendor settings via
  `--extra KEY=VALUE` (hardware-owned keys are refused).
