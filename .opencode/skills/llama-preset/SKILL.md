---
name: llama-preset
description: Erzeugt oder optimiert einen [section]-Eintrag in llama.cpp/presets/models.ini für ein lokal vorhandenes GGUF, abgestimmt auf agentische Nutzung. Misst statt zu schätzen (llama-server --list-devices, llama-fit-params an mehreren ctx-Punkten), leitet alle Feature-Entscheidungen aus dem --help des installierten Builds ab statt aus einer festen Liste, wählt das KV-Cache-Paar backendabhängig, prüft das im GGUF eingebettete Chat-Template auf Verhaltens-Defaults und übernimmt Sampling nur als vollständiges Set aus der Modellkarte. Zeigt einen OPTIMIZATION DIFF gegen eine bestehende Section und erhält dabei Schlüssel, die sie nicht verwaltet. Triggert bei "models.ini erstellen/anpassen", "llama.cpp Modell konfigurieren", "Preset für <Modell> generieren/optimieren", "ctx-size / n-gpu-layers / n-cpu-moe für mein System bestimmen", "Modell an meine GPU anpassen", "bestehendes Preset optimieren". Nur für das llama.cpp-Tooling in diesem Repo, nicht für opencode- oder Claude-Config.
---

# llama-preset — hardware- and agentic-tuned `models.ini` sections

Given a model name, produce the **best quality/speed settings for agentic use**
on **this** machine, using the **newest features the installed llama.cpp build
actually supports**, and write them as a `[section]` in
`llama.cpp/presets/models.ini`. This applies equally whether the section is new
or already exists — re-running on an existing model re-tunes it and reports
what changed (see step 4/5).

**The governing rule: measure, don't reason.** Every number in a preset should
come from a tool that reported it, on this machine, in this build. Where a
measurement contradicts a rule below, the measurement wins and the rule gets
rewritten — that is how the backend-dependent KV rule and the ctx policy below
came to exist. Where something could not be measured, say so in the summary
instead of presenting a guess as a fact.

Four independent inputs drive every setting:

1. **Hardware fit** — derived from what is actually installed:
   - GPU(s), total/free VRAM and driver, via `llama-server --list-devices`
     (reports CUDA and Vulkan devices alike; the backend follows from the
     device id and changes the KV-cache decision, see below).
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
   - `cache-type-v` — **depends on the backend, not on quantization sensitivity
     alone.** On CUDA it must equal K: a mixed pair falls off the fused
     FlashAttention kernel. Measured 2026-08-04 on an RTX 4090 with
     gemma-4-31B @ ctx 65536 + MTP — `q8_0`/`q8_0` gave 2391 t/s prompt and
     86 t/s generation, `q8_0`/`q4_0` gave 32 and 9. A 9× throughput loss is
     never worth the KV memory. On Vulkan `q4_0` remains the V floor and frees
     the most KV memory of any single setting; the collapse above is **untested
     there**, so do not generalise it in either direction.
   - `parallel = 1`, `cache-reuse`, `reasoning-format = auto` (when supported).
   - Speculative decoding is **lossless** — the target verifies every drafted
     token — so a bad fit costs speed and never output quality. Wire whatever
     the build offers: `draft-mtp` when the model has an MTP head, plus
     `ngram-mod`, which needs no draft model and no VRAM and therefore applies
     to every model. Priority is hardcoded in llama.cpp, not by list order.
   - **Context beats nothing, but throughput beats context.** Do not buy a
     longer `ctx-size` with `n-cpu-moe`: offloaded experts put a PCIe round
     trip in the generation path, and long agent sessions are dominated by
     generation. Shrink `ctx-size` until it fits fully on the GPU instead
     (`--allow-cpu-moe` opts into the other trade if you really want it).
   - Sampling: model cards publish **whole sets** (thinking/general,
     thinking/coding, instruct), and they are not interchangeable parts. Adopt
     one set completely — for agentic work the coding/precise one — and never
     move a single value across sets. A `presence-penalty` from a general set
     dropped into a coding set punishes repeated tokens, which is what code is
     made of. Never `temp = 0` unless the card explicitly recommends greedy
     decoding; the script refuses a bare `--extra temp=0` without
     `--zero-temp-ok`.
   - **Exception: OCR/document-parsing models** (section name matches "ocr") keep the
     old conservative defaults (`f16` KV, no parallel/cache-reuse/speculative-
     decoding, no zero-temp guard) — one-shot greedy grounding doesn't benefit
     from (and isn't a creativity trade-off for) agentic throughput tuning.
   - See the decision reference below for exactly which keys this covers.
3. **Newest-feature detection** — this repo's llama.cpp is kept current, so the
   installed build is the authority on what is possible, and the script must
   never carry its own idea of the feature set. Every key above is gated on the
   **installed** `llama-server --help`/`--version`, and the *values* are parsed
   out of `--help` too, not listed here: the allowed `cache-type-k/v` types and
   the `--spec-type` implementations both come from that output. A new release
   that adds a speculator or a KV type therefore improves the next run without
   an edit, and an older build degrades gracefully with a printed note.
   If you find yourself about to hardcode a value that `--help` already states,
   parse it instead.
4. **Embedded chat template** — behavioural defaults live in the GGUF's own
   Jinja template and can contradict the model card. Laguna-XS-2.1 advertises
   interleaved reasoning as its headline feature while its template opens with
   `enable_thinking | default(false)`; a preset that trusts the card runs it
   with thinking off and nothing reports it. The script scans for this. Two
   traps: the template sits *after* the tensor-name table, past the 100 MB mark
   on a 40-layer MoE, so a short `strings` window finds nothing — and a missing
   hit then reads like a negative result when it only means you looked in the
   wrong place. Always confirm the template was seen before concluding anything
   from its absence.

`scripts/recommend.sh` does the measuring and the mechanical decisions. It is
not the judge: it cannot read a model card, it cannot weigh a 600 MiB margin
against 32k more context, and it reports the template finding rather than acting
on it. Run it, then decide those yourself — and if its output contradicts a
measurement you took by hand, trust the measurement and fix the script.

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
`models.ini` is the **bare model alias** clients pass in the OpenAI `model`
field — the directory the GGUF lives in, e.g. `[Laguna-XS-2.1]`, not
`[Laguna-XS-2.1-IQ4_XS.gguf]`. Getting this wrong creates a second, duplicate
section for a model that is already configured. If unsure which models exist:
`bash llama.cpp/server.sh --list`. It doesn't matter whether the model is brand
new or already has a `[section]` in `models.ini` — the same command re-tunes an
existing entry to the current hardware **and** the current agentic defaults
(see step 4/5); there is no separate "optimize an existing preset" workflow.

### 2. Inspect hardware + autosize (dry-run first)
```sh
bash .opencode/skills/llama-preset/scripts/recommend.sh "<model>"
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
bash .opencode/skills/llama-preset/scripts/recommend.sh "<model>" --hf-url
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

### 3b. Pin down `ctx-size` by measurement, not by one probe
The script reports a single fitted value. Before accepting it, probe the
**neighbouring** points and record them — the choice is a margin decision, and
a number without its neighbours cannot be reviewed:

```sh
M=~/.local/share/llama.cpp/models/<dir>/<file>.gguf
for c in 131072 163840 196608 262144; do
  printf 'ctx %-7s ' $c
  llama-fit-params -m "$M" -ngl -1 -fa on -ctk q8_0 -ctv q8_0 -c $c -fitp on \
    | awk '/^CUDA0|^Vulkan0/{printf "= %d MiB\n", $2+$3+$4}'
done
```

Pick by remaining headroom, and write the alternatives into `AGENTS.md` so the
next reader sees what was rejected and why. Roughly 1.5 GiB free has been the
working target on a 24 GB card; below ~600 MiB is a gamble that assumes nothing
else ever claims VRAM. Two caveats this repo has already hit:
- `llama-fit-params` rejects `--spec-type`, so for a model with an MTP head the
  reported total **excludes the drafter's context** and is a lower bound. Say so.
- A Windows-host binary given a `/mnt/c/...` path prints its header and no data
  line — a silent failure that reads exactly like "does not fit". If the memory
  numbers come back empty, check the path form before believing the verdict.

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
bash .opencode/skills/llama-preset/scripts/recommend.sh "<model>" --write \
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
If the server OOMs on the GPU, drop `ctx-size` first — that is the cheapest
lever and the one this repo has always used. Do not reach for `n-cpu-moe`, and
do not push a KV type below its floor; both trade generation throughput or
quality for memory. Re-verify after each change, and record the number you
ended up with plus the one that failed.

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
| Single discrete GPU, model fits VRAM | `device = <GPU>`, `n-gpu-layers = -1` |
| Model larger than VRAM (**dense**) | lower `n-gpu-layers` to the largest count that fits (fit-params computes it) |
| Model larger than VRAM (**MoE**, e.g. A3B/A4B) | keep `n-gpu-layers = -1`, push experts to CPU with `n-cpu-moe = N` (raise N = less VRAM, slower) |
| Discrete + integrated GPU present | pin `device = <discreteGPU>`; do **not** offload to the iGPU |
| True multi-GPU (2+ discrete) | `tensor-split = a,b` and/or `main-gpu`, `split-mode = layer` |
| Non-OCR model (**agentic default, K floor**) | `cache-type-k = q8_0` — never lower by default; K (attention keys) is more sensitive to quantization loss than V |
| Non-OCR model on **Vulkan** (V floor) | `cache-type-v = q4_0` — frees the most KV memory of any single setting |
| Non-OCR model on **CUDA / anything else** | `cache-type-v = cache-type-k` — a mixed pair falls off the fused FlashAttention kernel (measured 86 -> 9 t/s generation); spend KV memory, not throughput |
| VRAM still tight after other adjustments | shrink `ctx-size` further — don't push either KV type below its floor, and don't reach for `n-cpu-moe` |
| MoE model, native ctx doesn't fit | shrink `ctx-size` until it fits fully on the GPU; `n-cpu-moe` only with `--allow-cpu-moe` (PCIe round trip in the generation path) |
| Non-OCR model (**agentic default**) | `parallel = 1` — one active conversation gets the full `ctx-size` and full throughput instead of being split across slots |
| Non-OCR model (**agentic default**, if the build supports `--cache-reuse`) | `cache-reuse = 256` — meant to reuse cached KV for repeated prefixes (system prompt, tool schemas) across turns. **`--help` listing the flag is not enough**: build 10243 accepts it and then logs `cache_reuse is not supported by this context, it will be disabled` on every model tried (4 architectures, 5 flag combinations). Emit it, but read the load log before claiming it does anything |
| Non-OCR model (**newest-feature default**, if the build supports `--reasoning-format`) | `reasoning-format = auto` — guarantees `reasoning_content`/tool-call separation regardless of the build's own default |
| Model has an MTP head (self-speculative HF "-MTP-" repo, or a sibling `mtp-*.gguf`), build supports `--spec-type` | `spec-type = draft-mtp` (+ `model-draft = <path>` for the sibling case), `spec-draft-n-max = 4` |
| **Any** model, if `--help` lists `ngram-mod` | chain it in: `spec-type = draft-mtp,ngram-mod` or bare `ngram-mod`. No draft model, no VRAM, lossless. Speed effect unmeasured on this repo's hardware — say so |
| Embedded template sets `enable_thinking \| default(false)` on an agentic model | `reasoning = on` explicitly; don't trust `--reasoning auto`. Fallback: `chat-template-kwargs = {"enable_thinking": true}` |
| **OCR / document-parsing model** (section name matches "ocr", or `--ocr`) | keep conservative `cache-type-k/v = f16`, no `parallel`/`cache-reuse`/`spec-type`/`reasoning-format`; deterministic sampling (`temp=0`, `top-k=1`) via vendor `--extra` — no `--zero-temp-ok` needed, exempt from the guard |
| Non-OCR model, vendor card sampling (step 3) | adopt ONE published set whole (the coding/precise one for agentic use); never mix values across sets; `temp = 0` requires `--zero-temp-ok` |
| Installed `llama-server` lacks a newer flag (`--cache-reuse`, `--reasoning-format`, `--spec-type`, or a KV quant type) | skip that key, print a note, fall back gracefully (e.g. `cache-type-v` falls back from `q4_0` to `q8_0`) — never emit a flag the build doesn't support |
| No usable GPU (Vulkan empty) | `n-gpu-layers = 0`; runs on CPU, set `threads` ≈ physical cores |
| Always | `flash-attn = on` (the matched-KV decision above assumes the fused kernel), `jinja = true` (needed for tool-calling/reasoning) |
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
- `n-gpu-layers = -1` means "all layers" and is clamped automatically.
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
- Never emit a mixed `cache-type-k`/`cache-type-v` pair on a non-Vulkan backend
  without saying why; the fused-FlashAttention collapse is measured, not
  theoretical.
- `--write` must never delete a key it does not manage. Sampling, `reasoning`
  and `cache-ram` are carried over and reported; if you apply the block by hand
  instead, carry them yourself.
- Preserve section order in `models.ini` — it is maintained by hand.
- Both preset files are edited on a Windows host too and may carry CRLF. Strip
  CR before matching section headers or sourcing config, or the script will
  report an existing section as new and append a duplicate.

## Files

- `scripts/recommend.sh` — probes the hardware and the installed
  llama-server (`--help`/`--version`, including the *allowed values* for
  `cache-type-k/v` and `--spec-type`), scans the GGUF's embedded chat template,
  applies the agentic tuning above (backend-dependent KV pair, `parallel`,
  `cache-reuse`, `reasoning-format`, speculative decoding incl. `ngram-mod`, the
  temp=0 guard — each gated on build support, skipped for OCR models), resolves
  the model card (`--hf-url`), and merges one `models.ini` section in place,
  accepting vendor settings via `--extra KEY=VALUE` (hardware/agentic-owned keys
  are refused) while carrying over keys it does not manage. Prints an
  OPTIMIZATION DIFF against any pre-existing section.

  Runs on both hosts: it resolves `llama-server` or `llama-server.exe`, strips
  CR from sourced config, and converts POSIX paths to Windows form when the
  binary is an `.exe` — that last one was a silent-failure bug, not a nicety.
