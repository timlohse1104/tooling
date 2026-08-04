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
#   --allow-cpu-moe  Allow n-cpu-moe to buy a longer ctx (default: shrink ctx and
#                    keep every expert on the GPU — generation throughput first)
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
ALLOW_CPU_MOE=0
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
        --allow-cpu-moe) ALLOW_CPU_MOE=1; shift ;;
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

# source config.env (real) or its .example for LLAMA_MODELS_DIR / LLAMA_PRESET.
# Strip CR first: these files are edited on both machines and a CRLF copy makes
# bash choke on every line ("$'\r': command not found").
source_cfg() {
    local f="$1" tmp
    tmp="$(mktemp)"
    tr -d '\r' < "$f" > "$tmp"
    # shellcheck disable=SC1090
    source "$tmp"
    rm -f "$tmp"
}
# Precedence, strongest first: an exported env var, the real config.env, the
# host's config.ps1, then config.env.example. The .example must come last — it
# assigns a Linux path unconditionally and would otherwise clobber both an
# exported value and the Windows host's real one.
_ENV_MODELS_DIR="${LLAMA_MODELS_DIR:-}"
_ENV_PRESET="${LLAMA_PRESET:-}"
if [[ -f "$LCPP/config.env" ]]; then
    source_cfg "$LCPP/config.env"
elif [[ -f "$LCPP/config.ps1" ]]; then
    _v="$(sed -n 's/^[[:space:]]*\$LLAMA_MODELS_DIR[[:space:]]*=[[:space:]]*"\(.*\)".*/\1/p' "$LCPP/config.ps1" | tr -d '\r' | head -n1)"
    if [[ "$_v" == *'$env:LOCALAPPDATA'* ]] && command -v cmd.exe >/dev/null 2>&1; then
        _lad="$(cd / && cmd.exe /c 'echo %LOCALAPPDATA%' 2>/dev/null | tr -d '\r\n')"
        [[ -n "$_lad" ]] && _v="${_v//'$env:LOCALAPPDATA'/$_lad}"
    fi
    _v="${_v//\\//}"
    [[ "$_v" =~ ^([A-Za-z]):/(.*)$ ]] && _v="/mnt/${BASH_REMATCH[1],,}/${BASH_REMATCH[2]}"
    if [[ -n "$_v" && "$_v" != *'$env:'* ]]; then
        LLAMA_MODELS_DIR="$_v"
    else
        note "found config.ps1 but could not resolve LLAMA_MODELS_DIR from it — export LLAMA_MODELS_DIR or create config.env"
    fi
    unset _v _lad
elif [[ -f "$LCPP/config.env.example" ]]; then
    source_cfg "$LCPP/config.env.example"
fi
[[ -n "$_ENV_MODELS_DIR" ]] && LLAMA_MODELS_DIR="$_ENV_MODELS_DIR"
[[ -n "$_ENV_PRESET" ]]     && LLAMA_PRESET="$_ENV_PRESET"
unset _ENV_MODELS_DIR _ENV_PRESET
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
    local name="$1" hit
    # -L: follow symlinks (vendor/ or its parents may be a symlink).
    # Prefer the extensionless Linux binary; fall back to the Windows .exe so
    # this works on the WSL/Windows host too, where vendor/ holds *.exe only.
    hit="$(find -L "$LCPP/vendor" -name "$name" -type f 2>/dev/null | head -n1)"
    [[ -z "$hit" ]] && hit="$(find -L "$LCPP/vendor" -name "$name.exe" -type f 2>/dev/null | head -n1)"
    printf '%s' "$hit"
}
SERVER_BIN="$(resolve_bin llama-server)"
FIT_BIN="$(resolve_bin llama-fit-params)"
[[ -n "$SERVER_BIN" ]] || err "llama-server not found under $LCPP/vendor. Run ./bootstrap.sh first."
export LD_LIBRARY_PATH="$(dirname "$SERVER_BIN"):${LD_LIBRARY_PATH:-}"

# If the resolved binaries are Windows .exe (WSL host), they cannot open a
# /mnt/c/... path and fail SILENTLY: llama-fit-params prints its header and no
# data line, which reads exactly like "the model does not fit" and produced a
# 4096 ctx for a model that measurably does 163840. Convert paths for both the
# probes and the emitted preset — llama-server on that host is the same .exe,
# so the preset needs the native form too.
IS_WIN_BIN=0
[[ "$SERVER_BIN" == *.exe ]] && IS_WIN_BIN=1
to_native_path() {
    local p="$1"
    [[ "$IS_WIN_BIN" == 1 ]] || { printf '%s' "$p"; return; }
    if command -v wslpath >/dev/null 2>&1 && wslpath -m "$p" >/dev/null 2>&1; then
        wslpath -m "$p"
    elif [[ "$p" =~ ^/mnt/([a-zA-Z])/(.*)$ ]]; then
        printf '%s:/%s' "${BASH_REMATCH[1]^^}" "${BASH_REMATCH[2]}"
    else
        printf '%s' "$p"
    fi
}

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

# Speculative-decoding implementations THIS build offers, parsed from the
# comma-separated list --help prints right after the --spec-type flag. The set
# grows with llama.cpp releases, so never hardcode it: probe, then pick from
# what is actually there.
SPEC_TYPES_ALLOWED="$(sed -n 's/^--spec-type[[:space:]]\{1,\}\([a-z0-9,._-]\{1,\}\).*/\1/p' <<< "$HELP_TEXT" | head -n1)"
spec_type_supported() {
    [[ -z "$SPEC_TYPES_ALLOWED" ]] && return 1    # unknown -> do not guess
    local list=" ${SPEC_TYPES_ALLOWED//,/ } "
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
# Section name = the bare model alias clients pass in the OpenAI "model" field,
# which is the directory the GGUF lives in (e.g. .../Laguna-XS-2.1/x.gguf ->
# [Laguna-XS-2.1]). This matches what models.ini actually uses; the GGUF
# filename would create a second, duplicate section for models already there.
SECTION="$(basename "$(dirname "$MODEL_PATH")")"
[[ -z "$SECTION" || "$SECTION" == "." || "$SECTION" == "models" ]] && SECTION="$(basename "$MODEL_PATH" .gguf)"
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
    # Strip CR: models.ini is edited on the Windows host too, and a CRLF copy
    # made "[$SECTION]" never match — the script then reported "new entry" for
    # an existing section, skipping the OPTIMIZATION DIFF and letting --write
    # append a duplicate.
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
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
# device + backend. Resolved before the KV-cache block because the correct
# cache-type pair depends on the backend, not just on quantization sensitivity.
# --------------------------------------------------------------------------- #
DEVICE="$(choose_device || true)"
if [[ -z "$DEVICE" ]]; then
    note "WARNING: no usable GPU detected — emitting a CPU-only preset."
fi

# Backend from the device id that --list-devices reported (CUDA0 / Vulkan0 / ...).
# Never hardcode which backend this repo uses; both machines exist.
BACKEND="cpu"
case "$DEVICE" in
    CUDA*|Cuda*|cuda*)     BACKEND="cuda" ;;
    Vulkan*|vulkan*)       BACKEND="vulkan" ;;
    ROCm*|HIP*|hip*)       BACKEND="rocm" ;;
    SYCL*|Metal*|metal*)   BACKEND="other" ;;
esac

# --------------------------------------------------------------------------- #
# agentic speculative-decoding auto-wiring. Speculative decoding is LOSSLESS —
# the target model verifies every drafted token — so a bad fit costs speed and
# never output quality. That asymmetry is why this is enabled aggressively.
#
# Which implementations exist is read from THIS build's --spec-type list, never
# hardcoded: the set grows with llama.cpp releases and this repo's server is
# kept current, so a new release should unlock a better default on the next run
# without editing this script.
#
# Two independent sources of drafts, and they chain:
#   * draft-model based (draft-mtp here) — needs an MTP head, either embedded
#     in an "-MTP-" HF build (Qwen3.6) or as a sibling mtp-*.gguf (gemma-4-31B,
#     needs model-draft pointed at it).
#   * draft-model free (ngram-mod) — needs nothing at all: a hash table in host
#     RAM, no VRAM, no extra weights. Applies to EVERY model, so it is added
#     whenever the build offers it.
# Priority is hardcoded inside llama.cpp (common/speculative.cpp), not by list
# order: every ngram-* runs before every draft-*, and the first implementation
# that produces a draft wins for that step.
#
# Skipped for OCR models, with --no-agentic, or if this build lacks --spec-type.
# --------------------------------------------------------------------------- #
SPEC_TYPE=""; SPEC_DRAFT=""; SPEC_SRC=""; SPEC_NGRAM=0
DRAFT_OVERHEAD_MIB=0
if [[ "$IS_OCR" == 0 && "$AGENTIC" == 1 ]]; then
    if ! supports_flag "spec-type"; then
        note "installed llama-server ($SERVER_VERSION) does not support --spec-type; skipping speculative decoding (upgrade llama.cpp to unlock it)"
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

    # Draft-model-free speculator: costs no VRAM and no weights, so it is
    # additive to whatever the MTP detection above found. Chain it in if this
    # build knows it; if the target model has no MTP head this is the only
    # speculator it can use at all.
    if supports_flag "spec-type" && spec_type_supported "ngram-mod"; then
        SPEC_NGRAM=1
        if [[ -n "$SPEC_TYPE" ]]; then
            SPEC_TYPE="${SPEC_TYPE},ngram-mod"
            SPEC_SRC="${SPEC_SRC}; chained with ngram-mod (no draft model, no VRAM — 16 MiB host-RAM hash table). Speed effect UNMEASURED, adopted on mechanism: lossless, so a bad fit costs speed only"
        else
            SPEC_TYPE="ngram-mod"
            SPEC_SRC="no MTP head found, but this build offers ngram-mod, which needs no draft model at all (16 MiB host RAM, no VRAM). Speed effect UNMEASURED, adopted on mechanism: lossless, so a bad fit costs speed only"
        fi
    elif [[ -n "$SPEC_TYPES_ALLOWED" ]]; then
        note "this build's --spec-type list does not offer 'ngram-mod' (offered: $SPEC_TYPES_ALLOWED); no draft-model-free speculator wired"
    fi
fi

# --------------------------------------------------------------------------- #
# embedded chat-template inspection.
#
# Behavioural defaults live in the GGUF's own Jinja template, not on the model
# card, and the two can disagree: Laguna-XS-2.1's card presents interleaved
# reasoning as the model's headline feature while its embedded template opens
# with `enable_thinking | default(false)`. A preset that trusts the card runs
# that model with thinking off and nothing reports it.
#
# The template sits in the GGUF metadata but AFTER the tensor-name table, which
# for a 40-layer MoE puts it past the 100 MB mark — a short `strings` window
# finds nothing and would produce a false "not present" answer. Scan wide, and
# verify the template was actually seen before drawing any conclusion.
# --------------------------------------------------------------------------- #
TEMPLATE_SCAN_MIB=200
TPL="$(head -c $((TEMPLATE_SCAN_MIB * 1024 * 1024)) "$MODEL_PATH" 2>/dev/null | strings -n 6 || true)"
if ! grep -q 'add_generation_prompt\|{%-' <<< "$TPL"; then
    note "chat template NOT found within the first ${TEMPLATE_SCAN_MIB} MiB of the GGUF — template-derived findings below are unavailable, not negative. Re-check by hand before assuming a default."
else
    if grep -q 'enable_thinking[[:space:]]*|[[:space:]]*default(false)' <<< "$TPL"; then
        note "embedded template sets 'enable_thinking | default(false)': THINKING IS OFF unless switched on. For an agentic model set 'reasoning = on' explicitly rather than trusting --reasoning auto. Fallback if that does not take: chat-template-kwargs = {\"enable_thinking\": true}"
    elif grep -q 'enable_thinking[[:space:]]*|[[:space:]]*default(true)' <<< "$TPL"; then
        note "embedded template defaults enable_thinking to true — no reasoning switch needed"
    fi
    if grep -q 'reasoning_content' <<< "$TPL"; then
        note "embedded template consumes 'reasoning_content' from history — the model expects preserved thinking; a client that drops thinking blocks will degrade it across turns"
    fi
fi

# --------------------------------------------------------------------------- #
# agentic KV-cache / concurrency / reasoning defaults (skipped for OCR, or
# with --no-agentic).
#
# K never goes below q8_0: attention keys degrade faster under quantization
# than values. What V may be depends on the BACKEND, not on quantization
# sensitivity alone:
#
#   cuda    -> V MUST equal K. A mixed pair falls off the fused FlashAttention
#              kernel. Measured 2026-08-04 on an RTX 4090 with gemma-4-31B
#              @ ctx 65536 + MTP: q8_0/q8_0 = 2391 t/s prompt / 86 t/s gen,
#              q8_0/q4_0 = 32 t/s / 9 t/s. Saving KV memory is not worth a
#              9x throughput loss.
#   vulkan  -> V may drop to q4_0 (frees the most KV memory of any single
#              setting). The mixed-pair collapse above is UNTESTED here.
#   other   -> treated like cuda: match the pair. Safer to lose KV memory than
#              to risk an unmeasured kernel fallback.
#
# Both values are validated against what THIS build's --cache-type-k/-v lists
# as supported, with a graceful fallback + note on older/narrower builds.
# --------------------------------------------------------------------------- #
CACHE_K="f16"; CACHE_V="f16"
CACHE_SRC="default f16 (max precision; OCR/no-agentic keep this conservative choice)"
PARALLEL_VAL=""; CACHE_REUSE_VAL=""; REASONING_VAL=""
if [[ "$IS_OCR" == 0 && "$AGENTIC" == 1 ]]; then
    CACHE_K="q8_0"
    if ! cache_type_supported "$CACHE_K"; then
        note "installed llama-server does not list 'q8_0' as a supported cache-type-k (allowed: ${CACHE_TYPES_ALLOWED:-unknown}); falling back to f16"
        CACHE_K="f16"
    fi
    case "$BACKEND" in
        vulkan)
            CACHE_V="q4_0"
            if ! cache_type_supported "$CACHE_V"; then
                note "installed llama-server does not list 'q4_0' as a supported cache-type-v (allowed: ${CACHE_TYPES_ALLOWED:-unknown}); falling back to $CACHE_K"
                CACHE_V="$CACHE_K"
            fi
            CACHE_SRC="agentic default (vulkan): k=q8_0 floor (keys are quantization-sensitive), v=q4_0 floor (values tolerate more, frees the most KV memory)"
            ;;
        *)
            CACHE_V="$CACHE_K"
            CACHE_SRC="agentic default ($BACKEND): k=q8_0 floor, v matched to k — a mixed pair falls off the fused FlashAttention kernel (measured 9x generation loss on CUDA), so KV memory is spent rather than throughput"
            ;;
    esac
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
if [[ "$CACHE_K" != "$CACHE_V" && "$BACKEND" != "vulkan" && "$IS_OCR" == 0 && "$AGENTIC" == 1 ]]; then
    note "WARNING: cache-type-k=$CACHE_K != cache-type-v=$CACHE_V on backend '$BACKEND'. A mixed pair fell off the fused FlashAttention kernel on CUDA (measured 86 -> 9 t/s generation). Verify throughput after loading, or match the pair."
fi

true   # DEVICE is resolved earlier (the KV-cache rule depends on the backend)
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
    local -a args=(-m "$(to_native_path "$MODEL_PATH")" --fit on -v)
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
    local -a args=(-m "$(to_native_path "$MODEL_PATH")" --fit on --fit-print on --fit-ctx 4096
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
    elif [[ "$IS_MOE" == 1 && -n "$N_LAYER" && "$ALLOW_CPU_MOE" == 1 ]]; then
        # binary search the smallest n-cpu-moe (of N_LAYER total layers) that
        # makes ctx=TARGET_CTX fit, by re-probing at each candidate.
        #
        # Opt-in only (--allow-cpu-moe). Buying context with n-cpu-moe moves
        # expert weights to host RAM and every token then waits on the PCIe
        # round trip, which is the opposite of what an agentic preset wants:
        # long multi-turn sessions are dominated by generation throughput, and
        # a shorter fully-resident context beats a longer half-offloaded one.
        # Default behaviour is therefore to shrink ctx-size instead (below).
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
    printf 'model = %s\n' "$(to_native_path "$MODEL_PATH")"
    [[ -n "$DEVICE" ]] && printf 'device = %s\n' "$DEVICE"
    printf 'ctx-size = %s            # %s\n' "$CTX_VAL" "$CTX_SRC"
    printf 'n-gpu-layers = %s        # %s\n' "$([[ "$NGL_VAL" == 999 ]] && echo -1 || echo "$NGL_VAL")" "$NGL_SRC"
    [[ -n "$NCMOE_VAL" ]] && printf 'n-cpu-moe = %s           # %s\n' "$NCMOE_VAL" "$NCMOE_SRC"
    printf 'flash-attn = on\n'
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
        [[ -n "$SPEC_DRAFT" ]] && printf 'model-draft = %s\n' "$(to_native_path "$SPEC_DRAFT")"
        printf 'spec-type = %s           # %s\n' "$SPEC_TYPE" "$SPEC_SRC"
        if [[ "$SPEC_TYPE" == *draft-* ]]; then
            printf 'spec-draft-n-max = 4     # lossless speculative decoding; lower if the drafter'"'"'s acceptance rate is poor\n'
        fi
        if [[ "$SPEC_NGRAM" == 1 ]]; then
            # These equal the build's own defaults; emitted so the values are
            # visible in the preset and so re-running produces no phantom diff
            # against the sections that already spell them out.
            printf 'spec-ngram-mod-n-match = 24\n'
            printf 'spec-ngram-mod-n-min = 48\n'
            printf 'spec-ngram-mod-n-max = 64\n'
        fi
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

# Keys the existing section has that the new block does not set. They are
# vendor/manual settings the script has no opinion about — model-card sampling,
# `reasoning`, `cache-ram`. Deleting them on --write would silently undo tuning
# that was done deliberately, so they are carried over verbatim and reported.
CARRY_KEYS=()
compute_carry() {
    local line seen=" " k
    while IFS= read -r line; do
        [[ "$line" =~ ^([A-Za-z0-9_-]+)[[:space:]]*= ]] && seen+="${BASH_REMATCH[1]} "
    done <<< "$BLOCK"
    for k in "${!OLD_KV[@]}"; do
        [[ "$seen" == *" $k "* ]] && continue
        CARRY_KEYS+=("$k")
    done
}
compute_carry
FINAL_BLOCK="$BLOCK"
if [[ ${#CARRY_KEYS[@]} -gt 0 ]]; then
    for _k in "${CARRY_KEYS[@]}"; do
        FINAL_BLOCK+=$'\n'"$_k = ${OLD_KV[$_k]}"
    done
    unset _k
fi

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
    for k in "${CARRY_KEYS[@]}"; do
        note "  = $k = ${OLD_KV[$k]}   (kept — not managed by this script)"
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
    # Replace the section IN PLACE. Three things this must not do:
    #   * match with a bare $0==sec — a CRLF file never matches, the old block
    #     survives and a duplicate section gets appended.
    #   * move the section to the end of the file — section order in models.ini
    #     is maintained by hand and must be preserved.
    #   * drop keys this script does not manage (sampling, reasoning, cache-ram);
    #     those are carried over, see compute_carry.
    awk -v sec="[$SECTION]" -v repl="$FINAL_BLOCK" '
        { line=$0; sub(/\r$/,"",line) }
        line==sec && !done { print repl; skip=1; done=1; next }
        skip && line ~ /^\[/ { skip=0 }
        !skip { print }
        END { if (!done) printf "\n%s\n", repl }
    ' "$PRESET_FILE" > "$tmp"
    mv "$tmp" "$PRESET_FILE"
    note "Updated [$SECTION] in $PRESET_FILE (in place; section order preserved)."
    if [[ ${#CARRY_KEYS[@]} -gt 0 ]]; then
        note "carried over ${#CARRY_KEYS[@]} key(s) this script does not manage: ${CARRY_KEYS[*]}"
    fi
}

if [[ "$DO_WRITE" == 1 ]]; then
    merge_into_preset
else
    note ""
    note "(dry-run) Re-run with --write to merge this section into $LLAMA_PRESET,"
    note "or copy the block above manually. Review the # source comments first."
fi
