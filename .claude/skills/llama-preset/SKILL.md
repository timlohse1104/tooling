---
name: llama-preset
description: Erzeugt bzw. aktualisiert für ein in models.list/auf dem System vorhandenes Modell den passenden [section]-Eintrag in llama.cpp/presets/models.ini — abgestimmt auf die real verbaute Hardware (GPU/VRAM via Vulkan, CPU-Kerne, RAM) UND auf beste Qualität/Geschwindigkeit für agentische Nutzung (Tool-Calling, Multi-Turn, lange Kontexte): cache-type-k=q8_0 (Floor), cache-type-v=q4_0 (Floor), parallel=1, cache-reuse, reasoning-format, automatisches lossless MTP-Speculative-Decoding — jeweils nur wenn die installierte llama-server-Version das Feature unterstützt (immer die neuesten verfügbaren Features nutzen, nie hart codieren). Niedrigere Sampling-Temperaturen werden für Determinismus bevorzugt, temp=0 aber nur wenn der Modell-Ersteller es explizit empfiehlt. Ausnahme: OCR/Dokumenten-Modelle behalten die konservativen Defaults. Optimiert auch bereits bestehende Sections (zeigt einen Diff). Triggert bei Anfragen wie "models.ini erstellen/anpassen", "llama.cpp Modell konfigurieren", "Preset für <Modell> generieren/optimieren", "n-gpu-layers / n-cpu-moe / ctx-size für mein System bestimmen", "Modell an meine GPU anpassen", "bestehendes Preset optimieren". Nutzt `llama-server --list-devices`, `llama-server --help` (Feature-Detection) und `llama-fit-params` zum Autosizing. Use ONLY for the llama.cpp tooling in this repo, not for editing opencode/Claude config.
---

# llama-preset — hardware- and agentic-tuned `models.ini` sections

Given a model name, produce the **best quality/speed settings for agentic use**
on **this** machine, using the **newest features the installed llama.cpp build
actually supports**, and write them as a `[section]` in
`llama.cpp/presets/models.ini`. This applies equally whether the section is new
or already exists — re-running on an existing model re-tunes it and reports
what changed (see step 4/5).

Three independent inputs drive every setting:

1. **Hardware fit** — derived from what is actually installed:
   - GPU(s), total/free VRAM and driver, via `llama-server --list-devices` (Vulkan).
   - Autosized `n-gpu-layers` / `n-cpu-moe` / `ctx-size`, via `llama-fit-params`
     (the same `--fit` engine `llama-server` uses), with a transparent file-size
     heuristic as fallback.
   - CPU physical cores and system RAM (for CPU-offload sizing).
   - The concrete hardware this repo targets (GPU model/VRAM, CPU, host names
     `lieselotte`/`hermine`) is documented in `llama.cpp/README.md` (intro) and
     `AGENTS.md` — **not** hardcoded in this skill or its script. Always re-probe
     the real machine; never assume specs from memory.
2. **Agentic quality/speed tuning** — settings that are not about "does it fit"
   but about the best quality/speed trade-off for tool-calling, multi-turn,
   long-context agent workloads:
   - `cache-type-k = q8_0` — the **floor** for K (never lower by default;
     attention keys are more sensitive to quantization loss).
   - `cache-type-v = q4_0` — the **floor** for V (values tolerate more
     aggressive quantization, especially with flash-attn; frees the most KV
     memory of any of these settings).
   - `parallel = 1`, `cache-reuse`, `reasoning-format = auto` (when supported),
     and auto-wired lossless MTP speculative decoding when the model has one.
   - Sampling **temperature** prefers the lower/more deterministic end of what
     the model card offers (agentic work is less creative, more deterministic)
     — but never `temp = 0` unless the model card explicitly recommends greedy
     decoding; the script refuses a bare `--extra temp=0` without an explicit
     `--zero-temp-ok` confirmation.
   - **Exception: OCR/document-parsing models** (e.g. `Unlimited-OCR`) keep the
     old conservative defaults (`f16` KV, no parallel/cache-reuse/speculative-
     decoding, no zero-temp guard) — one-shot greedy grounding doesn't benefit
     from (and isn't a creativity trade-off for) agentic throughput tuning.
   - See the decision reference below for exactly which keys this covers.
3. **Newest-feature detection** — every agentic-tuned key above (KV-cache
   quant type, `cache-reuse`, `reasoning-format`, `spec-type`) is gated on the
   **installed** `llama-server --help`/`--version` actually supporting it, with
   a graceful fallback + note if the build is older/narrower. Never hardcode a
   flag set; re-probe every run, so `bootstrap.sh --force` immediately unlocks
   better defaults next time.

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

### 1. Identify the model + check whether a section already exists
Accept a section name, a `.gguf` filename, or a full path. The section header in
`models.ini` equals the GGUF filename (e.g. `[Qwen3.6-27B-IQ4_XS-mtp.gguf]`),
matching the existing convention. If unsure which models exist:
`bash llama.cpp/server.sh --list`. It doesn't matter whether the model is brand
new or already has a `[section]` in `models.ini` — the same command re-tunes an
existing entry to the current hardware **and** the current agentic defaults
(see step 4/5); there is no separate "optimize an existing preset" workflow.

### 2. Inspect hardware + autosize (dry-run first)
```sh
bash .claude/skills/llama-preset/scripts/recommend.sh "<model>"
```
This prints the installed `llama-server` version, the device table, model
facts (size, MoE?, `n_layer`, `n_ctx_train`), the chosen device, the raw
`llama-fit-params` output, the **agentic tuning** block (mode, KV-cache type,
parallel/cache-reuse/`reasoning-format`, speculative-decoding detection — each
already gated on what the installed build supports), and a ready `[section]`
block. Useful flags:
- `--device Vulkan0` force a specific GPU (default: best **discrete** GPU; the
  script penalises integrated GPUs such as Intel UHD/Iris).
- `--ctx N` force context size (otherwise fit chooses, capped at `n_ctx_train`).
- `--margin MiB` VRAM headroom to leave free per device (default `1024`).
- `--cache-k TYPE` / `--cache-v TYPE` override the KV-cache quant (default
  `q8_0`/`q4_0` floors, or `f16`/`f16` for OCR models) — e.g. drop `--cache-v`
  further (`q4_1`/`iq4_nl`) if VRAM is still too tight after other adjustments;
  the script warns if the installed build doesn't list the value as supported,
  or if you push `--cache-k` more aggressive than `q8_0`.
- `--ocr` force OCR/document-parsing mode (skip agentic extras) if the section
  name doesn't contain "ocr" but the model is still a one-shot grounding model.
- `--no-agentic` disable ALL agentic extras (`parallel`/`cache-reuse`/speculative
  decoding) for a non-OCR model — e.g. when the router will actually serve
  several concurrent clients against this model and you want `parallel > 1`
  instead (set the concurrency you want via `--extra parallel=N` in that case).
- `--zero-temp-ok` confirm the model card explicitly recommends `temp = 0`
  (greedy decoding) — required before `--extra temp=0` is accepted for a
  non-OCR model (see step 3/4); without it the script refuses the value and
  keeps sampling non-degenerate.
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
  "non-thinking" presets often differ). **For agentic/tool-use, prefer the
  lower / more deterministic option the card offers** (e.g. its "coding" or
  "non-thinking"/"instruction-following" preset over its "creative writing"
  one, or the low end of a stated range) — agentic work benefits from less
  randomness. **Never set `temp = 0`** unless the card itself explicitly
  recommends greedy/deterministic decoding for that model; the script refuses
  a bare `--extra temp=0` unless you also pass `--zero-temp-ok` to confirm
  that's genuinely what the card says (not just your own preference for
  determinism — some sampling diversity is still wanted; see the `SKILL.md`
  intro for the "no creativity no fun" rationale). OCR models are exempt from
  this guard (see step 2).
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
Check the **AGENTIC TUNING** block: for a normal (non-OCR) model this should
show `q8_0`/`q4_0` KV-cache, `parallel = 1`, `cache-reuse`, `reasoning-format`
(or "not supported by this build" — both are fine, just confirm it matches
what `--help` on the installed binary actually offers), and either a detected
`spec-type=draft-mtp` (self-speculative HF repo or sibling `mtp-*.gguf`) or an
explicit "no embedded/sibling MTP drafter found". Verify `mode` reads
`OCR/document (agentic extras skipped)` for OCR models and `agentic
(quality+speed tuned)` for everything else — correct with `--ocr` /
`--no-agentic` if the auto-detection got it wrong. If any note says the
installed build doesn't support a feature (`does not support --cache-reuse`,
`does not list 'q4_0' as a supported cache-type-v`, etc.), that's the
"newest-feature" gate working as intended on an older build — mention it in
the summary (step 7) rather than silently ignoring it; `bootstrap.sh --force`
resolves it if a newer llama.cpp release is desired.

If a `[section]` already existed, also read the **OPTIMIZATION DIFF** printed
near the end of the report (dry-run already computes and shows it, before
`--write` is even needed): `~ key: old -> new` for changed values, `+ key =
value (new)` for additions, `- key = value (dropped)` for keys the new
tuning no longer sets. This is exactly how "optimize an already-configured
model" surfaces — review it like a code diff before merging.

### 5. Merge into the preset
Re-run with `--write` and pass the model-card findings as `--extra KEY=VALUE`
(repeatable). Hardware- and agentic-owned keys always win: an `--extra` that
collides with a key the script tuned for this hardware/agentic-use is
**refused** (reported on stderr), never silently overridden — exactly the rule
"only set what the hardware/agentic step did not already set".
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
drop `ctx-size` first; `cache-type-v` is already at its `q4_0` floor by default,
so if still tight after that, shrink `ctx-size` further rather than dropping
either KV type below its floor (that would undo the agentic quality/speed
tuning) — re-verify after each change.

### 7. Summarize
Report: model, chosen device + VRAM, final `n-gpu-layers` / `n-cpu-moe` /
`ctx-size` and their source; the agentic tuning applied (KV-cache type,
`parallel`, `cache-reuse`, speculative-decoding detection, or the OCR
exception if it applied); which vendor settings were added from the model
card (and any that were refused as hardware/agentic-owned); the
**OPTIMIZATION DIFF** if a section already existed; and whether `models.ini`
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
| Non-OCR model (**agentic default, K floor**) | `cache-type-k = q8_0` — never lower by default; K (attention keys) is more sensitive to quantization loss than V |
| Non-OCR model (**agentic default, V floor**) | `cache-type-v = q4_0` — tolerates more aggressive quantization than K (especially with flash-attn); frees the most KV memory of any of these settings |
| VRAM still tight after other adjustments | shrink `ctx-size` further — don't push either KV type below its floor |
| Non-OCR model (**agentic default**) | `parallel = 1` — one active conversation gets the full `ctx-size` and full throughput instead of being split across slots |
| Non-OCR model (**agentic default**, if the build supports `--cache-reuse`) | `cache-reuse = 256` — reuses cached KV for repeated prefixes (system prompt, tool schemas) across turns |
| Non-OCR model (**newest-feature default**, if the build supports `--reasoning-format`) | `reasoning-format = auto` — guarantees `reasoning_content`/tool-call separation regardless of the build's own default |
| Model has an MTP head (self-speculative HF "-MTP-" repo, or a sibling `mtp-*.gguf` file), and the build supports `--spec-type` | `spec-type = draft-mtp` (+ `model-draft = <path>` for the sibling-file case), `spec-draft-n-max = 4` — lossless speedup, auto-detected |
| **OCR / document-parsing model** (section name matches "ocr", or `--ocr`) | keep conservative `cache-type-k/v = f16`, no `parallel`/`cache-reuse`/`spec-type`/`reasoning-format`; deterministic sampling (`temp=0`, `top-k=1`) via vendor `--extra` — no `--zero-temp-ok` needed, exempt from the guard |
| Non-OCR model, vendor card sampling (step 3) | prefer the model card's lower/more deterministic temp option; `temp = 0` requires `--zero-temp-ok` to confirm the card actually recommends greedy decoding |
| Installed `llama-server` lacks a newer flag (`--cache-reuse`, `--reasoning-format`, `--spec-type`, or a KV quant type) | skip that key, print a note, fall back gracefully (e.g. `cache-type-v` falls back from `q4_0` to `q8_0`) — never emit a flag the build doesn't support |
| No usable GPU (Vulkan empty) | `n-gpu-layers = 0`; runs on CPU, set `threads` ≈ physical cores |
| Always | `flash-attn = auto`, `jinja = true` (needed for tool-calling/reasoning) |
| Vendor/model card (step 3) | sampling `temp`/`top-p`/`top-k`/`min-p`/`repeat-penalty`, `chat-template[-file]`, `rope-scaling`/`yarn-*` — via `--extra` |

Three classes of settings:
- **Hardware-owned** (tuned to the detected machine): `device`, `n-gpu-layers`,
  `n-cpu-moe`, `ctx-size`, `flash-attn`, `jinja`, plus `model`/`alias`.
- **Agentic-owned** (tuned for quality/speed under agentic use, from the actual
  files/repo/build present — not vendor advice): `cache-type-k/v`, `parallel`,
  `cache-reuse`, `reasoning-format`, `spec-type`, `model-draft`,
  `spec-draft-n-max`. Skipped/reset to conservative values for OCR models or
  with `--no-agentic`; individually skipped if the installed build doesn't
  support the flag (newest-feature gate).
- **Vendor-owned** (from the model card, supplied via `--extra`): everything
  else, e.g. sampling and prompt-template keys. They only fill gaps the
  hardware/agentic steps left open — both of the classes above always win over
  a colliding `--extra`. Exception within this class: `temp = 0` is refused
  without `--zero-temp-ok` (non-OCR only) — see step 3.

Notes:
- `n-gpu-layers = 999` means "all layers" and is clamped automatically.
- `ctx-size` must not exceed the model's `n_ctx_train` (the script caps it). If
  the vendor documents YaRN/RoPE to extend it, that is a deliberate override —
  raise `--ctx` explicitly rather than fighting the cap.
- `device` values come from `--list-devices` (e.g. `Vulkan0`), comma-separated
  for multiple.
- MTP detection: the script tells self-speculative models (HF repo name
  contains "MTP", e.g. `unsloth/Qwen3.6-27B-MTP-GGUF`) apart from models
  needing a separate drafter (a sibling `mtp-*.gguf` next to the model file,
  e.g. gemma-4-31B) — read the `spec-type`/`model-draft` `# source` comment to
  see which case applied, or "no embedded/sibling MTP drafter found" if neither.
- Newest-feature detection: the script runs `llama-server --help`/`--version`
  once per invocation and only emits `cache-reuse`, `reasoning-format`,
  `spec-type`, or a given KV quant type if that build's `--help` actually lists
  it, printing a `does not support`/`does not list` note and a graceful
  fallback otherwise (e.g. `cache-type-v` falls back `q4_0` → `q8_0` → `f16` as
  needed). This means the exact keys in a generated section can differ between
  machines running different llama.cpp releases — that's intentional, not drift.

## Safety / repo rules

- `presets/models.ini` is **gitignored** (machine-specific paths) — never commit
  it, and never commit `*.gguf`. Only `presets/models.example.ini` is tracked.
- Model paths must be **absolute** and point inside `$LLAMA_MODELS_DIR` (outside
  the repo).
- Edit exactly the one `[section]` you were asked about; leave others untouched
  — even when re-optimizing an existing entry.
- Never hardcode this repo's hardware (GPU/VRAM/CPU/RAM) into the skill or the
  script; it is documented in `llama.cpp/README.md` and `AGENTS.md` and can
  change per machine — always re-probe via `--list-devices`/`lscpu`/`free`.
- Never hardcode an assumed llama-server flag set either — always re-probe
  `--help`/`--version` so the newest available features are used and older
  builds degrade gracefully instead of erroring on an unknown flag.
- Never fabricate VRAM/layer numbers — if `llama-fit-params` output can't be
  parsed, say so and use the labelled heuristic, then verify by actually loading.
- Never copy a vendor setting you did not actually find on the model card, and
  never let a vendor `--extra` override a hardware- or agentic-tuned key (the
  script refuses it; keep it that way).
- Never accept a bare `temp = 0` for a non-OCR model without `--zero-temp-ok`;
  don't pass that flag yourself unless the model card genuinely recommends
  greedy decoding — determinism is preferred, but not at the cost of all
  sampling diversity ("no creativity no fun").
- Do **not** apply agentic tuning (`cache-type-k/v` floors, `parallel`,
  `cache-reuse`, `reasoning-format`, speculative decoding, the zero-temp guard)
  to OCR/document-parsing models — verify `--ocr` was auto-detected or forced
  for those.

## Files

- `scripts/recommend.sh` — probe hardware + the installed llama-server's
  supported features (`--help`/`--version`) + apply agentic quality/speed
  tuning (KV-cache quant floors `q8_0`/`q4_0`, `parallel`, `cache-reuse`,
  `reasoning-format`, auto-detected MTP speculative decoding, a temp=0 guard —
  each gated on build support, skipped for OCR models) + look up the model
  card (`--hf-url`) + merge one `models.ini` section, accepting vendor settings
  via `--extra KEY=VALUE` (hardware/agentic-owned keys are refused) + print an
  OPTIMIZATION DIFF against any pre-existing section.
