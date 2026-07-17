#!/usr/bin/env bash
#
# recommend.sh — derive hardware-tuned llama-server settings for one GGUF model
# and emit (or merge) the matching [section] block for llama.cpp/presets/models.ini.
#
# It inspects the ACTUAL machine via the bootstrapped llama.cpp binaries:
#   * `llama-server --list-devices`  -> GPU(s), total/free VRAM (as Vulkan sees them)
#   * `llama-fit-params ... --fit-print on`  -> autosized n-gpu-layers / n-cpu-moe / ctx
# and falls back to a transparent file-size heuristic when fit output can't be parsed.
#
# It NEVER guesses values silently: every emitted key carries a trailing comment
# stating its source (llama-fit-params | heuristic | default | model-card).
#
# In addition to raw hardware fit, the script applies AGENTIC tuning defaults —
# settings that are not about "does it fit" but about best quality/speed for
# agentic (tool-calling, multi-turn, long-context) usage:
#   - cache-type-k = q8_0 (the FLOOR for K — attention keys are more sensitive
#     to quantization loss, never go lower by default)
#   - cache-type-v = q4_0 (the FLOOR for V — values tolerate more aggressive
#     quantization, especially with flash-attn; frees the most KV memory)
#   - parallel=1 (one conversation gets the full ctx-size and full throughput
#     instead of splitting it across slots)
#   - cache-reuse (fast prefix reuse for repeated system prompts / tool
#     schemas across turns)
#   - reasoning-format=auto, when the build supports it (guarantees proper
#     reasoning_content/tool_call separation regardless of the build's own
#     default)
#   - auto-wired lossless MTP speculative decoding when the model has it
#     (self-speculative HF "-MTP-" repos, or a sibling mtp-*.gguf drafter file)
# Sampling temperature is vendor-owned (step 3), but prefer the LOWER end of
# what the model card offers for agentic/tool-use (determinism over
# creativity) — never all the way to temp=0 unless the model card explicitly
# recommends greedy decoding; passing --extra temp=0 without confirming that
# is refused unless --zero-temp-ok is also given (OCR models are exempt, see
# below — deterministic extraction there isn't a creativity trade-off).
# EXCEPTION: models detected as OCR/document-parsing (section name matches
# "ocr") are left on the old conservative defaults (f16 KV, no parallel/
# cache-reuse/speculative-decoding) since one-shot greedy grounding doesn't
# benefit from them; force/undo detection with --ocr / --no-agentic.
#
# The script is idempotent both ways: re-running --write on a model that
# already has a [section] in models.ini re-tunes it to the current hardware
# AND the current agentic defaults (fixing drift, e.g. an old f16 KV-cache or
# a missing parallel/cache-reuse/spec-type), and prints an OPTIMIZATION DIFF
# against the previous section so you can see exactly what changed.
#
# ALWAYS USE THE NEWEST LLAMA.CPP FEATURES AVAILABLE: the script probes the
# installed llama-server's --help/--version once (never hardcodes a flag set)
# and only emits a feature-gated key (cache-reuse, reasoning-format, the exact
# cache-type-k/v quant, spec-type) if the installed build actually supports
# it, falling back gracefully with a note on older builds. Re-running
# bootstrap.sh --force to update llama.cpp and then re-running this script is
# how newly-available features get adopted.
#
# Vendor / model-card best practices (sampling, chat template, RoPE/YaRN, ...) are
# NOT derivable from hardware. This script prints the HuggingFace model-card URL(s)
# from models.list so the caller can read them, and accepts those settings back via
# --extra KEY=VALUE. Hardware-owned keys always win: an --extra that collides with a
# key this script already set for the detected hardware is refused (not overridden).
#
# The concrete hardware this repo targets (GPU model/VRAM, CPU, RAM) is documented
# in llama.cpp/README.md (intro) and AGENTS.md, not hardcoded here — this script
# always re-probes the actual machine via --list-devices/lscpu/free instead.
#
# Usage:
#   recommend.sh <model>            [options]   # model = section name, filename, or path
#   recommend.sh --list-devices                 # just print the parsed device table
#   recommend.sh <model> --hf-url               # just print the model-card URL(s) and exit
#
# Options:
#   --device DEV     Force offload device(s), e.g. Vulkan0 (default: best discrete GPU)
#   --ctx N          Force ctx-size (default: let fit choose, capped at n_ctx_train)
#   --margin MiB     VRAM to leave free per device for compute buffers (default: 1024)
#   --cache-k TYPE   Override cache-type-k (default: q8_0 floor, or f16 for OCR models)
#   --cache-v TYPE   Override cache-type-v (default: q4_0 floor, or f16 for OCR models)
#   --ocr            Force OCR/document-parsing mode (skip agentic extras)
#   --no-agentic     Disable ALL agentic extras (parallel/cache-reuse/spec-decoding)
#                    for a non-OCR model, e.g. when serving multiple parallel clients
#   --zero-temp-ok   Confirm the model card explicitly recommends temp=0 (greedy);
#                    required to pass --extra temp=0 on a non-OCR model
#   --extra K=V      Add a vendor/model-card key (repeatable); skipped if hardware-owned
#   --write          Merge the generated section into presets/models.ini (idempotent)
#   --llama-dir DIR  Path to the repo's llama.cpp/ dir (default: auto-detected)
#   -h, --help
#
set -euo pipefail

# --------------------------------------------------------------------------- #
# arg parsing
# --------------------------------------------------------------------------- #
MODEL_INPUT=""
FORCE_DEVICE=""
FORCE_CTX=""
MARGIN_MIB=1024
DO_WRITE=0
LLAMA_DIR=""
ONLY_DEVICES=0
HF_ONLY=0
FORCE_OCR=0
AGENTIC=1
FORCE_CACHE_K=""
FORCE_CACHE_V=""
ZERO_TEMP_OK=0
declare -a EXTRA_KV=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) sed -n '2,85p' "$0"; exit 0 ;;
        --list-devices) ONLY_DEVICES=1; shift ;;
        --hf-url)   HF_ONLY=1; shift ;;
        --device)   FORCE_DEVICE="${2:?--device needs a value}"; shift 2 ;;
        --ctx)      FORCE_CTX="${2:?--ctx needs a value}"; shift 2 ;;
        --margin)   MARGIN_MIB="${2:?--margin needs a value}"; shift 2 ;;
        --cache-k)  FORCE_CACHE_K="${2:?--cache-k needs a value}"; shift 2 ;;
        --cache-v)  FORCE_CACHE_V="${2:?--cache-v needs a value}"; shift 2 ;;
        --ocr)      FORCE_OCR=1; shift ;;
        --no-agentic) AGENTIC=0; shift ;;
        --zero-temp-ok) ZERO_TEMP_OK=1; shift ;;
        --extra)    EXTRA_KV+=("${2:?--extra needs KEY=VALUE}"); shift 2 ;;
        --write)    DO_WRITE=1; shift ;;
        --llama-dir) LLAMA_DIR="${2:?--llama-dir needs a value}"; shift 2 ;;
        --*) printf 'Unknown option: %s\n' "$1" >&2; exit 1 ;;
        *)   MODEL_INPUT="$1"; shift ;;
    esac
done

err()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
note() { printf '%s\n' "$*" >&2; }
trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }

# Keys this script owns for the detected hardware + agentic tuning. --extra
# values matching any of these are refused so vendor defaults can never
# override the hardware/agentic tuning (parallel/cache-reuse/spec-* are
# auto-derived from this machine's actual files, not from vendor advice).
RESERVED_KEYS="alias model device ctx-size n-gpu-layers n-cpu-moe flash-attn cache-type-k cache-type-v jinja parallel cache-reuse spec-type model-draft spec-draft-n-max reasoning-format"
is_reserved() { [[ " $RESERVED_KEYS " == *" $1 "* ]]; }

# --------------------------------------------------------------------------- #
# locate the repo's llama.cpp/ tooling dir (holds vendor/, presets/, config.env)
# --------------------------------------------------------------------------- #
find_llama_dir() {
    [[ -n "$LLAMA_DIR" ]] && { printf '%s' "$LLAMA_DIR"; return; }
    [[ -n "${LLAMA_TOOLING_DIR:-}" ]] && { printf '%s' "$LLAMA_TOOLING_DIR"; return; }
    local d
    # walk up from CWD, then from this script's location
    for start in "$PWD" "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; do
        d="$start"
        while [[ "$d" != "/" ]]; do
            if [[ -f "$d/llama.cpp/server.sh" && -d "$d/llama.cpp/presets" ]]; then
                printf '%s' "$d/llama.cpp"; return
            fi
            if [[ -f "$d/server.sh" && -d "$d/presets" ]]; then
                printf '%s' "$d"; return
            fi
            d="$(dirname "$d")"
        done
    done
    err "Could not locate the llama.cpp tooling dir. Pass --llama-dir or set LLAMA_TOOLING_DIR."
}

LCPP="$(find_llama_dir)"

# source config.env (real) or its .example for LLAMA_MODELS_DIR / LLAMA_PRESET
if   [[ -f "$LCPP/config.env" ]];         then source "$LCPP/config.env"
elif [[ -f "$LCPP/config.env.example" ]]; then source "$LCPP/config.env.example"
fi
LLAMA_MODELS_DIR="${LLAMA_MODELS_DIR:-$HOME/.local/share/llama.cpp/models}"
LLAMA_PRESET="${LLAMA_PRESET:-presets/models.ini}"
PRESET_FILE="$LCPP/$LLAMA_PRESET"
MANIFEST="$LCPP/models.list"

# --------------------------------------------------------------------------- #
# model-card lookup: map the model back to its HuggingFace repo via models.list
# (repo_id | filename | dest_subdir). Emits TSV: mark <tab> repo <tab> file <tab> url
# "mark" = MATCH when the manifest filename equals the section or its dest_subdir
# is a path component of the resolved model file; otherwise blank.
# --------------------------------------------------------------------------- #
hf_candidates() {
    [[ -f "$MANIFEST" ]] || return 0
    local line repo file dest mark
    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line//[[:space:]]/}" ]] && continue
        IFS='|' read -r repo file dest <<< "$line"
        repo="$(trim "$repo")"; file="$(trim "$file")"; dest="$(trim "${dest:-}")"
        [[ -z "$repo" ]] && continue
        mark="-"
        if [[ "$file" == "${SECTION:-}" ]] || { [[ -n "$dest" && -n "${MODEL_PATH:-}" ]] && [[ "$MODEL_PATH" == *"/$dest/"* ]]; }; then
            mark="MATCH"
        fi
        printf '%s\t%s\t%s\thttps://huggingface.co/%s\n' "$mark" "$repo" "$file" "$repo"
    done < "$MANIFEST"
}

# --------------------------------------------------------------------------- #
# locate llama-server / llama-fit-params and wire up shared libs
# --------------------------------------------------------------------------- #
resolve_bin() {
    local name="$1"
    # -L: follow symlinks (vendor/ or its parents may be a symlink)
    find -L "$LCPP/vendor" -name "$name" -type f 2>/dev/null | head -n1
}
SERVER_BIN="$(resolve_bin llama-server)"
FIT_BIN="$(resolve_bin llama-fit-params)"
[[ -n "$SERVER_BIN" ]] || err "llama-server not found under $LCPP/vendor. Run ./bootstrap.sh first."
export LD_LIBRARY_PATH="$(dirname "$SERVER_BIN"):${LD_LIBRARY_PATH:-}"

# --------------------------------------------------------------------------- #
# feature detection: probe the INSTALLED llama-server's --help/--version so
# every "newest feature" decision below is based on what this build actually
# supports, not on what a past/other build supported. Never hardcode a flag
# set — always re-probe, so upgrading llama.cpp (bootstrap.sh --force)
# automatically unlocks better defaults next time this script runs.
# --------------------------------------------------------------------------- #
SERVER_VERSION="$("$SERVER_BIN" --version 2>&1 | head -n1 || true)"
HELP_TEXT="$("$SERVER_BIN" --help 2>&1 || true)"

# true if the installed build's --help mentions this long flag at all
supports_flag() {
    [[ -n "$1" ]] && grep -qF -- "$1" <<< "$HELP_TEXT"
}

# KV cache quant types this build actually accepts for -ctk/-ctv (parsed from
# the "allowed values: ..." line right after --cache-type-k TYPE in --help).
CACHE_TYPES_ALLOWED="$(awk '/--cache-type-k TYPE/{getline; print}' <<< "$HELP_TEXT" | sed -n 's/.*allowed values: *//p')"
cache_type_supported() {
    [[ -z "$CACHE_TYPES_ALLOWED" ]] && return 0   # unknown help format -> assume supported
    local list=" ${CACHE_TYPES_ALLOWED//,/ } "
    [[ "$list" == *" $1 "* ]]
}

# --------------------------------------------------------------------------- #
# device discovery  (parses `llama-server --list-devices`)
#   line shape:  "  Vulkan0: AMD Radeon RX 7900 XTX (RADV NAVI31) (24560 MiB, 12861 MiB free)"
# emits TSV rows: id <tab> total_mib <tab> free_mib <tab> integrated(0|1) <tab> name
# --------------------------------------------------------------------------- #
parse_devices() {
    "$SERVER_BIN" --list-devices 2>/dev/null | while IFS= read -r line; do
        if [[ "$line" =~ ^[[:space:]]*([^:]+):[[:space:]]*(.*)\(([0-9]+)[[:space:]]*MiB,[[:space:]]*([0-9]+)[[:space:]]*MiB[[:space:]]*free\)[[:space:]]*$ ]]; then
            local id="${BASH_REMATCH[1]}" name="${BASH_REMATCH[2]}" total="${BASH_REMATCH[3]}" free="${BASH_REMATCH[4]}"
            name="${name%"${name##*[![:space:]]}"}"   # rtrim
            local integ=0
            shopt -s nocasematch
            [[ "$name" =~ (intel|integrated|igpu|uhd|iris|radeon[[:space:]]graphics|raptor|rpl) ]] && integ=1
            shopt -u nocasematch
            printf '%s\t%s\t%s\t%s\t%s\n' "$id" "$total" "$free" "$integ" "$name"
        fi
    done
}

DEVICES_TSV="$(parse_devices || true)"

print_device_table() {
    printf 'Detected Vulkan devices:\n'
    if [[ -z "$DEVICES_TSV" ]]; then
        printf '  (none — running on CPU only; check GPU drivers / vulkaninfo)\n'
        return
    fi
    printf '  %-9s %-9s %-9s %-5s %s\n' ID TOTAL FREE iGPU NAME
    while IFS=$'\t' read -r id total free integ name; do
        [[ -z "$id" ]] && continue
        printf '  %-9s %-6sMiB %-6sMiB %-5s %s\n' "$id" "$total" "$free" "$([[ $integ == 1 ]] && echo yes || echo no)" "$name"
    done <<< "$DEVICES_TSV"
}

# choose the best device: prefer non-integrated with the largest TOTAL VRAM,
# otherwise the largest device overall (CPU fallback if none).
choose_device() {
    [[ -n "$FORCE_DEVICE" ]] && { printf '%s' "$FORCE_DEVICE"; return; }
    [[ -z "$DEVICES_TSV" ]] && return
    awk -F'\t' '
        { id=$1; total=$2+0; integ=$4+0;
          score = total - (integ ? 1000000 : 0);   # heavily penalise iGPUs
          if (score > best) { best=score; bid=id; btot=total } }
        END { if (bid != "") print bid }
    ' <<< "$DEVICES_TSV"
}

device_total_mib() {
    local dev="$1"
    awk -F'\t' -v d="$dev" '$1==d{print $2}' <<< "$DEVICES_TSV"
}

# --------------------------------------------------------------------------- #
# --list-devices shortcut
# --------------------------------------------------------------------------- #
if [[ "$ONLY_DEVICES" == 1 ]]; then
    print_device_table
    exit 0
fi

[[ -n "$MODEL_INPUT" ]] || err "No model given. Usage: recommend.sh <section|filename|path> [options]"

# --------------------------------------------------------------------------- #
# resolve the model file from a section name / filename / path
# --------------------------------------------------------------------------- #
resolve_model_path() {
    local in="$1"
    if [[ -f "$in" ]]; then printf '%s' "$in"; return; fi
    local -a hits=()
    # exact filename match first, then fuzzy contains (-L: follow symlinked dirs)
    mapfile -t hits < <(find -L "$LLAMA_MODELS_DIR" -type f -name "$in" 2>/dev/null)
    [[ ${#hits[@]} -eq 0 ]] && mapfile -t hits < <(find -L "$LLAMA_MODELS_DIR" -type f -name "${in%.gguf}.gguf" 2>/dev/null)
    [[ ${#hits[@]} -eq 0 ]] && mapfile -t hits < <(find -L "$LLAMA_MODELS_DIR" -type f -name "*${in%.gguf}*.gguf" 2>/dev/null)
    if [[ ${#hits[@]} -eq 0 ]]; then
        err "No GGUF matching '$in' under $LLAMA_MODELS_DIR. Download it first (./download-model.sh)."
    elif [[ ${#hits[@]} -gt 1 ]]; then
        { printf 'Ambiguous model "%s" — matches:\n' "$in"; printf '  %s\n' "${hits[@]}"; } >&2
        err "Pass a more specific name or the full path."
    fi
    printf '%s' "${hits[0]}"
}

MODEL_PATH="$(resolve_model_path "$MODEL_INPUT")"
SECTION="$(basename "$MODEL_PATH")"
MODEL_BYTES="$(stat -c '%s' "$MODEL_PATH" 2>/dev/null || echo 0)"
MODEL_MIB=$(( MODEL_BYTES / 1024 / 1024 ))

# compute the HuggingFace model-card match once; reused by --hf-url, the final
# report, and the embedded-MTP detection below.
HC="$(hf_candidates)"
HC_MATCH_REPO="$(awk -F'\t' '$1=="MATCH"{print $2; exit}' <<< "$HC")"

# --hf-url shortcut: print the model-card URL(s) and exit (no fit/load needed)
if [[ "$HF_ONLY" == 1 ]]; then
    if [[ -z "$HC" ]]; then
        note "No models.list entry matched '$SECTION'. Search HuggingFace for it manually."
        exit 0
    fi
    printf '%-6s %-42s %s\n' MATCH REPO_ID URL
    while IFS=$'\t' read -r mark repo file url; do
        printf '%-6s %-42s %s\n' "$mark" "$repo" "$url"
    done <<< "$HC"
    exit 0
fi

# --------------------------------------------------------------------------- #
# read an existing [SECTION] from presets/models.ini (if any), so we can later
# report an OPTIMIZATION DIFF instead of silently clobbering it.
# --------------------------------------------------------------------------- #
declare -A OLD_KV=()
load_existing_section() {
    [[ -f "$PRESET_FILE" ]] || return 0
    local insec=0 line key val
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" == "[$SECTION]" ]]; then insec=1; continue; fi
        if [[ $insec == 1 && "$line" =~ ^\[ ]]; then break; fi
        if [[ $insec == 1 && "$line" =~ ^([A-Za-z0-9_-]+)[[:space:]]*=[[:space:]]*(.*)$ ]]; then
            key="${BASH_REMATCH[1]}"; val="$(trim "${BASH_REMATCH[2]%%#*}")"
            OLD_KV["$key"]="$val"
        fi
    done < "$PRESET_FILE"
}
load_existing_section

# MoE detection: filename hints (A3B/A4B/MoE/xNbE) — refined by fit log if available.
IS_MOE=0
shopt -s nocasematch
[[ "$SECTION" =~ (a3b|a4b|a2b|moe|mixtral|-a[0-9]+b) ]] && IS_MOE=1
shopt -u nocasematch

# --------------------------------------------------------------------------- #
# OCR/document-parsing exception: these models are excluded from agentic
# quality/speed tuning (they want deterministic one-shot greedy grounding,
# not multi-turn throughput). Detected from the section name; force with --ocr.
# --------------------------------------------------------------------------- #
IS_OCR=0
shopt -s nocasematch
[[ "$SECTION" =~ ocr ]] && IS_OCR=1
shopt -u nocasematch
[[ "$FORCE_OCR" == 1 ]] && IS_OCR=1

# --------------------------------------------------------------------------- #
# agentic speculative-decoding auto-wiring: lossless MTP speeds up generation
# for free (the target model verifies every drafted token) whenever the model
# actually has an MTP head available. Two shapes seen in this repo:
#   1) self-speculative: the HF repo itself is an "-MTP-" build (Qwen3.6) —
#      no separate drafter file, just spec-type=draft-mtp.
#   2) separate drafter: a tiny sibling mtp-*.gguf next to the model
#      (gemma-4-31B) — needs model-draft pointed at that file too.
# Skipped for OCR models, with --no-agentic, or if this build lacks --spec-type
# (newest-feature gate: only use it if the installed llama-server supports it).
# --------------------------------------------------------------------------- #
SPEC_TYPE=""; SPEC_DRAFT=""; SPEC_SRC=""
DRAFT_OVERHEAD_MIB=0
if [[ "$IS_OCR" == 0 && "$AGENTIC" == 1 ]]; then
    if ! supports_flag "spec-type"; then
        note "installed llama-server ($SERVER_VERSION) does not support --spec-type; skipping MTP speculative decoding (upgrade llama.cpp to unlock it)"
    elif [[ -n "$HC_MATCH_REPO" && "$HC_MATCH_REPO" =~ [Mm][Tt][Pp] ]]; then
        SPEC_TYPE="draft-mtp"
        SPEC_SRC="HF repo ($HC_MATCH_REPO) is an MTP build — embedded self-speculative head, no separate drafter file needed"
    else
        DRAFTER="$(find -L "$(dirname "$MODEL_PATH")" -maxdepth 1 -type f -iname '*mtp*.gguf' ! -iname "$(basename "$MODEL_PATH")" 2>/dev/null | head -n1)"
        if [[ -n "$DRAFTER" ]]; then
            SPEC_TYPE="draft-mtp"; SPEC_DRAFT="$DRAFTER"
            SPEC_SRC="sibling drafter found next to the model: $(basename "$DRAFTER")"
            # A separate MTP drafter file adds real VRAM cost on top of the target
            # model that llama-fit-params cannot estimate for us: it has no
            # standalone --model-draft support, and MTP heads can't even be
            # loaded alone (they require the target's own context: "Gemma4Assistant
            # requires ctx_other to be set"). Use the drafter file's own size in
            # MiB as an honest proxy for its weight footprint (it has no separate
            # KV-cache of its own — it shares the target's context) and add it to
            # every fit budget check below so we don't silently under-count VRAM.
            DRAFTER_BYTES="$(stat -c '%s' "$DRAFTER" 2>/dev/null || echo 0)"
            DRAFT_OVERHEAD_MIB=$(( DRAFTER_BYTES / 1024 / 1024 ))
        fi
    fi
fi

# --------------------------------------------------------------------------- #
# agentic KV-cache / concurrency / reasoning defaults (skipped for OCR, or
# with --no-agentic). Floors reflect asymmetric quantization sensitivity: K
# (attention keys) degrades faster under quantization than V (values,
# especially with flash-attn), so K never goes below q8_0 by default while V
# can go as low as q4_0 — both are validated against what THIS build's
# --cache-type-k/-v actually lists as supported (newest-feature gate), with a
# graceful fallback + note if the installed llama-server is older/narrower.
# --------------------------------------------------------------------------- #
CACHE_K="f16"; CACHE_V="f16"
CACHE_SRC="default f16 (max precision; OCR/no-agentic keep this conservative choice)"
PARALLEL_VAL=""; CACHE_REUSE_VAL=""; REASONING_VAL=""
if [[ "$IS_OCR" == 0 && "$AGENTIC" == 1 ]]; then
    CACHE_K="q8_0"; CACHE_V="q4_0"
    if ! cache_type_supported "$CACHE_K"; then
        note "installed llama-server does not list 'q8_0' as a supported cache-type-k (allowed: ${CACHE_TYPES_ALLOWED:-unknown}); falling back to f16"
        CACHE_K="f16"
    fi
    if ! cache_type_supported "$CACHE_V"; then
        note "installed llama-server does not list 'q4_0' as a supported cache-type-v (allowed: ${CACHE_TYPES_ALLOWED:-unknown}); falling back to q8_0"
        CACHE_V="q8_0"
    fi
    CACHE_SRC="agentic default: cache-type-k=q8_0 is the floor for K (attention keys are more sensitive to quantization loss), cache-type-v=q4_0 is the floor for V (values tolerate more aggressive quantization, especially with flash-attn) — frees the most KV memory for long agentic context at near-lossless quality"
    PARALLEL_VAL=1
    if supports_flag "cache-reuse"; then
        CACHE_REUSE_VAL=256
    else
        note "installed llama-server ($SERVER_VERSION) does not support --cache-reuse; skipping prefix-reuse speedup (upgrade llama.cpp to unlock it)"
    fi
    if supports_flag "reasoning-format"; then
        REASONING_VAL="auto"
    fi
fi
if [[ -n "$FORCE_CACHE_K" ]]; then
    if ! cache_type_supported "$FORCE_CACHE_K"; then
        note "WARNING: '$FORCE_CACHE_K' is not in this build's allowed cache-type-k values (${CACHE_TYPES_ALLOWED:-unknown}) — setting it anyway, verify at load"
    fi
    case "$FORCE_CACHE_K" in
        q8_0|bf16|f16|f32) ;;
        *) note "WARNING: cache-type-k below q8_0 (got '$FORCE_CACHE_K') is more aggressive than recommended — K is more sensitive to quantization than V" ;;
    esac
    CACHE_K="$FORCE_CACHE_K"; CACHE_SRC="forced via --cache-k/--cache-v"
fi
if [[ -n "$FORCE_CACHE_V" ]]; then
    if ! cache_type_supported "$FORCE_CACHE_V"; then
        note "WARNING: '$FORCE_CACHE_V' is not in this build's allowed cache-type-v values (${CACHE_TYPES_ALLOWED:-unknown}) — setting it anyway, verify at load"
    fi
    CACHE_V="$FORCE_CACHE_V"; CACHE_SRC="forced via --cache-k/--cache-v"
fi

DEVICE="$(choose_device || true)"
if [[ -z "$DEVICE" ]]; then
    note "WARNING: no usable GPU detected — emitting a CPU-only preset."
fi
DEV_TOTAL=0
[[ -n "$DEVICE" ]] && DEV_TOTAL="$(device_total_mib "$DEVICE")"

# --------------------------------------------------------------------------- #
# hardware fit: probe llama-fit-params for the REAL per-device memory need
# (model weights, KV-cache/context, compute buffer) at the agentic KV-cache
# types decided above, and derive n-gpu-layers / n-cpu-moe / ctx-size that
# ACTUALLY fit — instead of a blind file-size heuristic.
#
# Two things learned the hard way from the installed build and worth stating
# explicitly: (1) llama-fit-params does NOT accept --jinja (server-only flag;
# passing it aborts before printing anything); (2) its own "--fit on" does not
# reliably shrink ctx-size to make things fit for every architecture — it can
# report a memory breakdown that overflows the device without adjusting
# anything. So this script owns the actual fit-to-VRAM decision, using
# --fit-print's real per-device MiB breakdown as ground truth, verified by
# re-probing after every candidate change (never a single blind guess).
# --------------------------------------------------------------------------- #
FIT_LOG=""
N_LAYER=""          # total offloadable layers, from "offloaded X/Y layers to GPU"
N_CTX_TRAIN=""
N_EXPERT=""

# One-off model metadata probe (~0.3-0.5s): n_ctx_train / total layer count /
# MoE expert count aren't in the plain --fit-print table, only in -v output.
probe_model_meta() {
    [[ -n "$FIT_BIN" ]] || return 0
    local -a args=(-m "$MODEL_PATH" --fit on -v)
    [[ -n "$DEVICE" ]] && args+=(--device "$DEVICE")
    local tmo=""; command -v timeout >/dev/null 2>&1 && tmo="timeout 60"
    local log; log="$($tmo "$FIT_BIN" "${args[@]}" 2>&1 || true)"
    FIT_LOG="$log"
    N_CTX_TRAIN="$(sed -n 's/.*n_ctx_train[^0-9]*\([0-9]\+\).*/\1/p' <<< "$log" | head -n1)"
    N_LAYER="$(sed -n 's/.*offloaded [0-9]\+\/\([0-9]\+\) layers to GPU.*/\1/p' <<< "$log" | head -n1)"
    N_EXPERT="$(sed -n 's/.*n_expert[^0-9=]*=\{0,1\} *\([0-9]\+\).*/\1/p' <<< "$log" | head -n1)"
    if [[ -n "$N_EXPERT" && "$N_EXPERT" -gt 1 ]]; then IS_MOE=1; fi
    return 0
}

# probe_fit CTX NCMOE -> sets P_MODEL/P_CTX/P_COMPUTE (target $DEVICE, MiB) and
# P_HOST_MODEL (Host, MiB) for that ctx-size / n-cpu-moe combination.
probe_fit() {
    local ctx="$1" ncmoe="$2"
    P_MODEL=""; P_CTX=""; P_COMPUTE=""; P_HOST_MODEL=""
    [[ -n "$FIT_BIN" && -n "$DEVICE" ]] || return 0
    local -a args=(-m "$MODEL_PATH" --fit on --fit-print on --fit-ctx 4096
                   --device "$DEVICE" --fit-target "$MARGIN_MIB"
                   -ctk "$CACHE_K" -ctv "$CACHE_V")
    [[ "$ctx" -gt 0 ]] && args+=(-c "$ctx")
    [[ -n "$ncmoe" && "$ncmoe" -gt 0 ]] && args+=(-ncmoe "$ncmoe")
    local tmo=""; command -v timeout >/dev/null 2>&1 && tmo="timeout 60"
    local out; out="$($tmo "$FIT_BIN" "${args[@]}" 2>&1 || true)"
    FIT_LOG="$out"
    P_MODEL="$(awk -v d="$DEVICE" '$1==d{print $2}' <<< "$out")"
    P_CTX="$(awk -v d="$DEVICE" '$1==d{print $3}' <<< "$out")"
    P_COMPUTE="$(awk -v d="$DEVICE" '$1==d{print $4}' <<< "$out")"
    P_HOST_MODEL="$(awk '$1=="Host"{print $2}' <<< "$out")"
    return 0
}

# true (exit 0) iff model+ctx+compute (+ any MTP drafter overhead) MiB fits
# within DEV_TOTAL - MARGIN_MIB
fits() {
    [[ -n "$1" && -n "$2" && -n "$3" ]] || return 1
    (( $1 + $2 + $3 + DRAFT_OVERHEAD_MIB <= DEV_TOTAL - MARGIN_MIB ))
}

DRAFT_NOTE=""
[[ "$DRAFT_OVERHEAD_MIB" -gt 0 ]] && DRAFT_NOTE=" + ~${DRAFT_OVERHEAD_MIB}MiB MTP drafter"

NGL_VAL=""; NGL_SRC=""
NCMOE_VAL=""; NCMOE_SRC=""
CTX_VAL=""; CTX_SRC=""

if [[ -z "$DEVICE" ]]; then
    NGL_VAL=0; NGL_SRC="heuristic: no GPU -> CPU only"
    CTX_VAL="${FORCE_CTX:-32768}"
    CTX_SRC="default 32768"; [[ -n "$FORCE_CTX" ]] && CTX_SRC="forced via --ctx"
elif [[ -z "$FIT_BIN" ]]; then
    note "llama-fit-params not present; using file-size heuristic only."
    if [[ "$DEV_TOTAL" -gt 0 && $(( MODEL_MIB + MARGIN_MIB + 2048 )) -le "$DEV_TOTAL" ]]; then
        NGL_VAL=999; NGL_SRC="heuristic: model (${MODEL_MIB}MiB) fits in ${DEV_TOTAL}MiB VRAM"
    else
        NGL_VAL=999; NGL_SRC="heuristic: too big to fully verify — start at 999 and lower if OOM"
    fi
    CTX_VAL="${FORCE_CTX:-32768}"
    CTX_SRC="default 32768"; [[ -n "$FORCE_CTX" ]] && CTX_SRC="forced via --ctx"
else
    probe_model_meta
    CTX_IS_FORCED=0; [[ -n "$FORCE_CTX" ]] && CTX_IS_FORCED=1
    TARGET_CTX="${FORCE_CTX:-${N_CTX_TRAIN:-32768}}"
    if [[ "$CTX_IS_FORCED" == 0 && -n "$N_CTX_TRAIN" && "$N_CTX_TRAIN" -gt 0 && "$TARGET_CTX" -gt "$N_CTX_TRAIN" ]]; then
        TARGET_CTX="$N_CTX_TRAIN"
    fi

    probe_fit "$TARGET_CTX" 0
    FOUND_NCMOE=""; SHRINK_NEEDED=0
    if fits "$P_MODEL" "$P_CTX" "$P_COMPUTE"; then
        NGL_VAL=999
        NGL_SRC="llama-fit-params: fits fully (needs ~$(( P_MODEL + P_CTX + P_COMPUTE + DRAFT_OVERHEAD_MIB ))MiB${DRAFT_NOTE} of $(( DEV_TOTAL - MARGIN_MIB ))MiB budget on $DEVICE at ctx=$TARGET_CTX)"
        CTX_VAL="$TARGET_CTX"
        CTX_SRC="llama-fit-params (native n_ctx_train, verified it fits)"
        [[ "$CTX_IS_FORCED" == 1 ]] && CTX_SRC="forced via --ctx, verified it fits"
    elif [[ "$IS_MOE" == 1 && -n "$N_LAYER" ]]; then
        # binary search the smallest n-cpu-moe (of N_LAYER total layers) that
        # makes ctx=TARGET_CTX fit, by re-probing at each candidate.
        bs_lo=1; bs_hi="$N_LAYER"
        while [[ "$bs_lo" -le "$bs_hi" ]]; do
            bs_mid=$(( (bs_lo + bs_hi) / 2 ))
            probe_fit "$TARGET_CTX" "$bs_mid"
            if fits "$P_MODEL" "$P_CTX" "$P_COMPUTE"; then
                FOUND_NCMOE="$bs_mid"; bs_hi=$(( bs_mid - 1 ))
            else
                bs_lo=$(( bs_mid + 1 ))
            fi
        done
        if [[ -n "$FOUND_NCMOE" ]]; then
            probe_fit "$TARGET_CTX" "$FOUND_NCMOE"
            NGL_VAL=999
            NGL_SRC="llama-fit-params: full ctx doesn't fit with all experts on GPU — n-cpu-moe=$FOUND_NCMOE found by binary search (needs ~$(( P_MODEL + P_CTX + P_COMPUTE + DRAFT_OVERHEAD_MIB ))MiB${DRAFT_NOTE} of $(( DEV_TOTAL - MARGIN_MIB ))MiB)"
            NCMOE_VAL="$FOUND_NCMOE"
            NCMOE_SRC="llama-fit-params: minimal value (of $N_LAYER layers) that fits at ctx=$TARGET_CTX"
            CTX_VAL="$TARGET_CTX"
            CTX_SRC="llama-fit-params (native n_ctx_train, fits once n-cpu-moe=$FOUND_NCMOE)"
            [[ "$CTX_IS_FORCED" == 1 ]] && CTX_SRC="forced via --ctx, fits once n-cpu-moe=$FOUND_NCMOE"
        else
            probe_fit "$TARGET_CTX" "$N_LAYER"
            note "even n-cpu-moe=$N_LAYER (all MoE experts on CPU) doesn't fit ctx=$TARGET_CTX — ${CTX_IS_FORCED:+ctx was forced, not shrinking further}${CTX_IS_FORCED:-shrinking ctx-size too}"
            NCMOE_VAL="$N_LAYER"
            NCMOE_SRC="llama-fit-params: all expert layers pushed to CPU, still tight at ctx=$TARGET_CTX"
            SHRINK_NEEDED=1
        fi
    else
        SHRINK_NEEDED=1
    fi

    if [[ "$SHRINK_NEEDED" == 1 && "$CTX_IS_FORCED" == 1 ]]; then
        # user explicitly forced --ctx: don't override it, just warn honestly
        NGL_VAL=999
        NGL_SRC="WARNING: forced ctx=$TARGET_CTX does not fit (${P_MODEL:-?}+${P_CTX:-?}+${P_COMPUTE:-?}MiB${DRAFT_NOTE} vs $(( DEV_TOTAL - MARGIN_MIB ))MiB budget) — lower --ctx, raise --margin's counterpart, or use a smaller quant"
        CTX_VAL="$TARGET_CTX"
        CTX_SRC="forced via --ctx — does NOT fit as probed, verify by loading"
    elif [[ "$SHRINK_NEEDED" == 1 ]]; then
        # not forced: shrink ctx-size proportionally (KV MiB scales ~linearly
        # with ctx for a fixed quant, minus any MTP drafter overhead), then
        # verify with real probes — retrying with a further 10% cut (bounded)
        # if the linear estimate slightly overshoots due to rounding/compute-
        # buffer variance, instead of reporting a single unverified guess.
        BUDGET=$(( DEV_TOTAL - MARGIN_MIB - P_MODEL - P_COMPUTE - DRAFT_OVERHEAD_MIB ))
        if [[ "$BUDGET" -gt 0 && -n "$P_CTX" && "$P_CTX" -gt 0 ]]; then
            NEW_CTX=$(awk -v b="$BUDGET" -v c="$P_CTX" -v t="$TARGET_CTX" 'BEGIN{n=int(b/(c/t)/4096)*4096; if(n<4096)n=4096; print n}')
        else
            NEW_CTX=4096
        fi
        SHRINK_TRY=0
        while true; do
            probe_fit "$NEW_CTX" "${NCMOE_VAL:-0}"
            if fits "$P_MODEL" "$P_CTX" "$P_COMPUTE"; then
                NGL_VAL=999
                NGL_SRC="llama-fit-params: native ctx=$TARGET_CTX doesn't fit — ctx-size reduced and re-verified"
                CTX_VAL="$NEW_CTX"
                CTX_SRC="llama-fit-params: largest ctx that fits${NCMOE_VAL:+ with n-cpu-moe=$NCMOE_VAL}${DRAFT_NOTE} (native n_ctx_train=$TARGET_CTX doesn't fit)"
                break
            fi
            SHRINK_TRY=$(( SHRINK_TRY + 1 ))
            if [[ "$NEW_CTX" -le 4096 || "$SHRINK_TRY" -ge 4 ]]; then
                NGL_VAL=999
                NGL_SRC="WARNING: does not fit even at ctx=$NEW_CTX (${P_MODEL:-?}+${P_CTX:-?}+${P_COMPUTE:-?}MiB${DRAFT_NOTE} vs $(( DEV_TOTAL - MARGIN_MIB ))MiB) — lower n-gpu-layers or use a smaller quant"
                CTX_VAL="$NEW_CTX"
                CTX_SRC="llama-fit-params: smallest attempted ctx, still tight — verify by loading"
                break
            fi
            NEW_CTX=$(( (NEW_CTX * 90 / 100 / 4096) * 4096 ))
            [[ "$NEW_CTX" -lt 4096 ]] && NEW_CTX=4096
        done
    fi
fi

# --------------------------------------------------------------------------- #
# build the [section] block
# --------------------------------------------------------------------------- #
build_block() {
    printf '[%s]\n' "$SECTION"
    printf 'alias = %s\n' "$SECTION"
    printf 'model = %s\n' "$MODEL_PATH"
    [[ -n "$DEVICE" ]] && printf 'device = %s\n' "$DEVICE"
    printf 'ctx-size = %s            # %s\n' "$CTX_VAL" "$CTX_SRC"
    printf 'n-gpu-layers = %s        # %s\n' "$NGL_VAL" "$NGL_SRC"
    [[ -n "$NCMOE_VAL" ]] && printf 'n-cpu-moe = %s           # %s\n' "$NCMOE_VAL" "$NCMOE_SRC"
    printf 'flash-attn = auto\n'
    printf 'cache-type-k = %s        # %s\n' "$CACHE_K" "$CACHE_SRC"
    printf 'cache-type-v = %s        # %s\n' "$CACHE_V" "$CACHE_SRC"
    printf 'jinja = true\n'
    if [[ -n "$PARALLEL_VAL" ]]; then
        printf 'parallel = %s            # agentic default: one active conversation gets the full ctx-size and full throughput instead of being split across slots\n' "$PARALLEL_VAL"
    fi
    if [[ -n "$CACHE_REUSE_VAL" ]]; then
        printf 'cache-reuse = %s          # agentic default: reuse cached KV for repeated prefixes (system prompt, tool schemas) across turns instead of recomputing\n' "$CACHE_REUSE_VAL"
    fi
    if [[ -n "$REASONING_VAL" ]]; then
        printf 'reasoning-format = %s    # newest-feature default: guarantees reasoning_content/tool_call separation on this llama-server build, regardless of its own default\n' "$REASONING_VAL"
    fi
    if [[ -n "$SPEC_TYPE" ]]; then
        [[ -n "$SPEC_DRAFT" ]] && printf 'model-draft = %s\n' "$SPEC_DRAFT"
        printf 'spec-type = %s           # %s\n' "$SPEC_TYPE" "$SPEC_SRC"
        printf 'spec-draft-n-max = 4     # lossless MTP speculative decoding speedup; lower if the drafter'"'"'s acceptance rate is poor\n'
    fi
    # vendor / model-card extras: only keys NOT owned by the hardware tuning above
    if [[ ${#EXTRA_KV[@]} -gt 0 ]]; then
        local kv key val seen=" "
        for kv in "${EXTRA_KV[@]}"; do
            [[ -z "$kv" ]] && continue
            key="$(trim "${kv%%=*}")"; val="$(trim "${kv#*=}")"
            [[ -z "$key" || "$key" == "$kv" ]] && { note "ignoring malformed --extra '$kv' (need KEY=VALUE)"; continue; }
            if is_reserved "$key"; then
                note "refused --extra '$key' — hardware/agentic-owned, kept the tuned value"
                continue
            fi
            # agentic sampling preference: lower temp favored for determinism, but
            # temp=0 (fully greedy, no creativity) requires an explicit --zero-temp-ok
            # confirmation that the model card actually recommends it (OCR models are
            # exempt — they're not "agentic" and determinism there isn't a trade-off).
            if [[ "$key" == "temp" && "$IS_OCR" == 0 ]]; then
                if [[ "$val" =~ ^0(\.0+)?$ && "$ZERO_TEMP_OK" != 1 ]]; then
                    note "refused --extra temp=$val — temp=0 kills sampling diversity; pass --zero-temp-ok only if the model card explicitly recommends greedy decoding"
                    continue
                fi
            fi
            [[ "$seen" == *" $key "* ]] && continue
            seen+="$key "
            printf '%s = %s        # model-card / vendor best practice\n' "$key" "$val"
        done
    fi
}
BLOCK="$(build_block)"

# --------------------------------------------------------------------------- #
# optimization diff vs the existing [SECTION] (if any) — makes re-tuning an
# already-configured model transparent instead of silently overwriting it.
# --------------------------------------------------------------------------- #
print_optimization_diff() {
    if [[ ${#OLD_KV[@]} -eq 0 ]]; then
        note "No existing [$SECTION] section in $PRESET_FILE — this will be a new entry."
        return
    fi
    note ""
    note "===== OPTIMIZATION DIFF vs existing [$SECTION] ====="
    local line key newval oldval seen=" "
    while IFS= read -r line; do
        [[ "$line" =~ ^([A-Za-z0-9_-]+)[[:space:]]*=[[:space:]]*([^#]*) ]] || continue
        key="${BASH_REMATCH[1]}"; newval="$(trim "${BASH_REMATCH[2]}")"
        seen+="$key "
        [[ "$key" == "alias" || "$key" == "model" ]] && continue
        oldval="${OLD_KV[$key]:-}"
        if [[ -z "$oldval" ]]; then
            note "  + $key = $newval   (new)"
        elif [[ "$oldval" != "$newval" ]]; then
            note "  ~ $key: $oldval -> $newval"
        fi
    done <<< "$BLOCK"
    local k
    for k in "${!OLD_KV[@]}"; do
        [[ "$seen" == *" $k "* ]] && continue
        note "  - $k = ${OLD_KV[$k]}   (no longer set — dropped or superseded)"
    done
    note "======================================================"
}

# --------------------------------------------------------------------------- #
# report
# --------------------------------------------------------------------------- #
{
    printf '\n===== HARDWARE =====\n'
    printf 'llama-server: %s\n' "${SERVER_VERSION:-unknown}"
    print_device_table
    printf 'CPU physical cores: %s   |   System RAM: %s\n' \
        "$( (command -v lscpu >/dev/null && c=$(lscpu | sed -n 's/^Core(s) per socket:[[:space:]]*//p') && s=$(lscpu | sed -n 's/^Socket(s):[[:space:]]*//p') && [[ "$c" =~ ^[0-9]+$ && "$s" =~ ^[0-9]+$ ]] && echo $((c*s)) ) 2>/dev/null || nproc)" \
        "$(free -h 2>/dev/null | awk '/^Mem|^Speicher/{print $2; exit}')"
    printf '\n===== MODEL =====\n'
    printf 'file      : %s\n' "$MODEL_PATH"
    printf 'size      : %s MiB\n' "$MODEL_MIB"
    printf 'section   : %s\n' "$SECTION"
    printf 'type      : %s%s\n' "$([[ $IS_MOE == 1 ]] && echo MoE || echo dense)" \
        "$([[ -n "$N_EXPERT" ]] && echo " (n_expert=$N_EXPERT)")"
    [[ -n "$N_LAYER" ]]     && printf 'n_layer   : %s\n' "$N_LAYER"
    [[ -n "$N_CTX_TRAIN" ]] && printf 'n_ctx_train: %s\n' "$N_CTX_TRAIN"
    printf 'target dev: %s%s\n' "${DEVICE:-CPU}" \
        "$([[ -n "$DEVICE" ]] && echo " (${DEV_TOTAL}MiB total, margin ${MARGIN_MIB}MiB)")"
    printf '\n===== AGENTIC TUNING =====\n'
    printf 'mode      : %s\n' "$([[ $IS_OCR == 1 ]] && echo "OCR/document (agentic extras skipped)" || { [[ $AGENTIC == 1 ]] && echo "agentic (quality+speed tuned)" || echo "disabled via --no-agentic"; })"
    printf 'cache-type: k=%s v=%s  (%s)\n' "$CACHE_K" "$CACHE_V" "$CACHE_SRC"
    [[ -n "$PARALLEL_VAL" ]] && printf 'parallel  : %s\n' "$PARALLEL_VAL"
    [[ -n "$CACHE_REUSE_VAL" ]] && printf 'cache-reuse: %s\n' "$CACHE_REUSE_VAL"
    if [[ "$IS_OCR" == 0 && "$AGENTIC" == 1 ]]; then
        printf 'reasoning-format: %s\n' "${REASONING_VAL:-not supported by this build}"
    fi
    if [[ -n "$SPEC_TYPE" ]]; then
        printf 'speculative: spec-type=%s (%s)\n' "$SPEC_TYPE" "$SPEC_SRC"
        [[ "$DRAFT_OVERHEAD_MIB" -gt 0 ]] && printf 'drafter VRAM: ~%sMiB (file size; llama-fit-params cannot estimate a separate MTP drafter, folded into the fit budget above)\n' "$DRAFT_OVERHEAD_MIB"
    else
        printf 'speculative: none (no embedded/sibling MTP drafter found)\n'
    fi
    printf '\n===== MODEL CARD (HuggingFace) =====\n'
    if [[ -n "$HC" ]]; then
        printf '  %-6s %-42s %s\n' MATCH REPO_ID URL
        while IFS=$'\t' read -r mark repo file url; do
            printf '  %-6s %-42s %s\n' "$mark" "$repo" "$url"
        done <<< "$HC"
        printf '  -> Read the model card for vendor best practices NOT derivable from hardware\n'
        printf '     (sampling: temp/top-p/top-k/min-p; chat-template; RoPE/YaRN for long ctx).\n'
        printf '     Feed them back as: --extra temp=0.6 --extra top-p=0.95 ...  (hardware keys are refused).\n'
    else
        printf '  (no models.list entry matched "%s"; search HuggingFace manually)\n' "$SECTION"
    fi
    if [[ -n "$FIT_LOG" ]]; then
        printf '\n----- llama-fit-params (final decision: ngl=%s ncmoe=%s ctx=%s) -----\n' \
            "${NGL_VAL:-?}" "${NCMOE_VAL:-?}" "${CTX_VAL:-?}"
        printf '(last probe run; see the # source comments below for how ngl/ncmoe/ctx were actually derived)\n'
        grep -iE 'fit|gpu_layers|cpu_moe|n_ctx|MiB|offload|memory' <<< "$FIT_LOG" | tail -n 10 || true
    fi
    print_optimization_diff
} >&2

printf '\n===== preset section for %s =====\n' "$LLAMA_PRESET"
printf '%s\n' "$BLOCK"

# --------------------------------------------------------------------------- #
# optional: merge into presets/models.ini (idempotent — replaces same section)
# --------------------------------------------------------------------------- #
merge_into_preset() {
    mkdir -p "$(dirname "$PRESET_FILE")"
    if [[ ! -f "$PRESET_FILE" ]]; then
        if [[ -f "$LCPP/presets/models.example.ini" ]]; then
            # keep only the leading comment header from the example
            awk '/^\[/{exit} {print}' "$LCPP/presets/models.example.ini" > "$PRESET_FILE"
        fi
        printf '%s\n' "$BLOCK" >> "$PRESET_FILE"
        note "Created $PRESET_FILE with section [$SECTION]."
        return
    fi
    local tmp; tmp="$(mktemp)"
    # drop an existing [SECTION] block (header until next [header] or EOF), keep the rest
    awk -v sec="[$SECTION]" '
        $0==sec {skip=1; next}
        skip && /^\[/ {skip=0}
        !skip {print}
    ' "$PRESET_FILE" > "$tmp"
    # trim trailing blank lines, then append the fresh block
    sed -e :a -e '/^\n*$/{$d;N;ba}' "$tmp" > "$tmp.2" 2>/dev/null || cp "$tmp" "$tmp.2"
    printf '\n%s\n' "$BLOCK" >> "$tmp.2"
    mv "$tmp.2" "$PRESET_FILE"; rm -f "$tmp"
    note "Updated [$SECTION] in $PRESET_FILE."
}

if [[ "$DO_WRITE" == 1 ]]; then
    merge_into_preset
else
    note ""
    note "(dry-run) Re-run with --write to merge this section into $LLAMA_PRESET,"
    note "or copy the block above manually. Review the # source comments first."
fi
