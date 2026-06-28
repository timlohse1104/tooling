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
# Vendor / model-card best practices (sampling, chat template, RoPE/YaRN, ...) are
# NOT derivable from hardware. This script prints the HuggingFace model-card URL(s)
# from models.list so the caller can read them, and accepts those settings back via
# --extra KEY=VALUE. Hardware-owned keys always win: an --extra that collides with a
# key this script already set for the detected hardware is refused (not overridden).
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
declare -a EXTRA_KV=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) sed -n '2,46p' "$0"; exit 0 ;;
        --list-devices) ONLY_DEVICES=1; shift ;;
        --hf-url)   HF_ONLY=1; shift ;;
        --device)   FORCE_DEVICE="${2:?--device needs a value}"; shift 2 ;;
        --ctx)      FORCE_CTX="${2:?--ctx needs a value}"; shift 2 ;;
        --margin)   MARGIN_MIB="${2:?--margin needs a value}"; shift 2 ;;
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

# Keys this script owns for the detected hardware. --extra values matching any of
# these are refused so vendor defaults can never override the hardware tuning.
RESERVED_KEYS="alias model device ctx-size n-gpu-layers n-cpu-moe flash-attn cache-type-k cache-type-v jinja"
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

# --hf-url shortcut: print the model-card URL(s) and exit (no fit/load needed)
if [[ "$HF_ONLY" == 1 ]]; then
    HC="$(hf_candidates)"
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

# MoE detection: filename hints (A3B/A4B/MoE/xNbE) — refined by fit log if available.
IS_MOE=0
shopt -s nocasematch
[[ "$SECTION" =~ (a3b|a4b|a2b|moe|mixtral|-a[0-9]+b) ]] && IS_MOE=1
shopt -u nocasematch

DEVICE="$(choose_device || true)"
if [[ -z "$DEVICE" ]]; then
    note "WARNING: no usable GPU detected — emitting a CPU-only preset."
fi
DEV_TOTAL=0
[[ -n "$DEVICE" ]] && DEV_TOTAL="$(device_total_mib "$DEVICE")"

# --------------------------------------------------------------------------- #
# run llama-fit-params to autosize (best-effort; output format may vary by build)
# --------------------------------------------------------------------------- #
FIT_LOG=""
FIT_NGL=""        # parsed n_gpu_layers
FIT_NCMOE=""      # parsed n_cpu_moe
FIT_CTX=""        # parsed ctx
N_LAYER=""
N_CTX_TRAIN=""
N_EXPERT=""

run_fit() {
    [[ -n "$FIT_BIN" ]] || { note "llama-fit-params not present; using heuristic only."; return; }
    local -a args=(-m "$MODEL_PATH" --fit on --fit-print on --fit-ctx 4096 -c "${FORCE_CTX:-0}" --jinja)
    [[ -n "$DEVICE" ]] && args+=(--device "$DEVICE")
    [[ -n "$DEVICE" ]] && args+=(--fit-target "$MARGIN_MIB")
    note "Running: llama-fit-params ${args[*]}"
    local tmo=""; command -v timeout >/dev/null 2>&1 && tmo="timeout 300"
    FIT_LOG="$($tmo "$FIT_BIN" "${args[@]}" 2>&1 || true)"

    # model metadata (printed at load by the common loader)
    N_LAYER="$(sed -n 's/.*n_layer[^0-9]*\([0-9]\+\).*/\1/p'      <<< "$FIT_LOG" | head -n1)"
    N_CTX_TRAIN="$(sed -n 's/.*n_ctx_train[^0-9]*\([0-9]\+\).*/\1/p' <<< "$FIT_LOG" | head -n1)"
    N_EXPERT="$(sed -n 's/.*n_expert[^0-9]*\([0-9]\+\).*/\1/p'    <<< "$FIT_LOG" | head -n1)"
    [[ -n "$N_EXPERT" && "$N_EXPERT" -gt 1 ]] && IS_MOE=1

    # fitted recommendation (tolerant: accept several spellings)
    FIT_NGL="$(sed -n 's/.*\(n_gpu_layers\|gpu_layers\|n-gpu-layers\)[^0-9]*\([0-9]\+\).*/\2/p' <<< "$FIT_LOG" | tail -n1)"
    FIT_NCMOE="$(sed -n 's/.*\(n_cpu_moe\|n-cpu-moe\|cpu_moe\)[^0-9]*\([0-9]\+\).*/\2/p'        <<< "$FIT_LOG" | tail -n1)"
    FIT_CTX="$(sed -n 's/.*\(n_ctx\|ctx_size\|ctx-size\)[^0-9]*\([0-9]\+\).*/\2/p'              <<< "$FIT_LOG" | tail -n1)"
}
run_fit

# --------------------------------------------------------------------------- #
# decide the final values (fit result wins; heuristic/default otherwise)
# --------------------------------------------------------------------------- #
NGL_VAL=""; NGL_SRC=""
NCMOE_VAL=""; NCMOE_SRC=""
CTX_VAL=""; CTX_SRC=""

# n-gpu-layers
if [[ -n "$FIT_NGL" ]]; then
    NGL_VAL="$FIT_NGL"; NGL_SRC="llama-fit-params"
elif [[ -z "$DEVICE" ]]; then
    NGL_VAL=0; NGL_SRC="heuristic: no GPU -> CPU only"
elif [[ "$DEV_TOTAL" -gt 0 && $(( MODEL_MIB + MARGIN_MIB + 2048 )) -le "$DEV_TOTAL" ]]; then
    NGL_VAL=999; NGL_SRC="heuristic: model (${MODEL_MIB}MiB) fits in ${DEV_TOTAL}MiB VRAM"
else
    NGL_VAL=999; NGL_SRC="heuristic: too big to fully verify — start at 999 and lower if OOM"
fi

# n-cpu-moe (only meaningful for MoE that does not fully fit)
if [[ "$IS_MOE" == 1 ]]; then
    if [[ -n "$FIT_NCMOE" ]]; then
        NCMOE_VAL="$FIT_NCMOE"; NCMOE_SRC="llama-fit-params"
    elif [[ "$DEV_TOTAL" -gt 0 && $(( MODEL_MIB + MARGIN_MIB + 2048 )) -gt "$DEV_TOTAL" && -n "$N_LAYER" ]]; then
        # rough: offload enough expert layers that the dense remainder fits
        NCMOE_VAL="$N_LAYER"; NCMOE_SRC="heuristic: MoE exceeds VRAM — keep all expert layers on CPU; lower to push more onto GPU"
    fi
fi

# ctx-size
if   [[ -n "$FORCE_CTX" ]]; then CTX_VAL="$FORCE_CTX"; CTX_SRC="forced via --ctx"
elif [[ -n "$FIT_CTX" ]];   then CTX_VAL="$FIT_CTX";   CTX_SRC="llama-fit-params"
else
    CTX_VAL=32768; CTX_SRC="default 32768"
    if [[ -n "$N_CTX_TRAIN" && "$N_CTX_TRAIN" -gt 0 && "$N_CTX_TRAIN" -lt "$CTX_VAL" ]]; then
        CTX_VAL="$N_CTX_TRAIN"; CTX_SRC="capped at n_ctx_train=$N_CTX_TRAIN"
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
    printf 'cache-type-k = f16\n'
    printf 'cache-type-v = f16\n'
    printf 'jinja = true\n'
    # vendor / model-card extras: only keys NOT owned by the hardware tuning above
    if [[ ${#EXTRA_KV[@]} -gt 0 ]]; then
        local kv key val seen=" "
        for kv in "${EXTRA_KV[@]}"; do
            [[ -z "$kv" ]] && continue
            key="$(trim "${kv%%=*}")"; val="$(trim "${kv#*=}")"
            [[ -z "$key" || "$key" == "$kv" ]] && { note "ignoring malformed --extra '$kv' (need KEY=VALUE)"; continue; }
            if is_reserved "$key"; then
                note "refused --extra '$key' — hardware-owned, kept the tuned value"
                continue
            fi
            [[ "$seen" == *" $key "* ]] && continue
            seen+="$key "
            printf '%s = %s        # model-card / vendor best practice\n' "$key" "$val"
        done
    fi
}
BLOCK="$(build_block)"

# --------------------------------------------------------------------------- #
# report
# --------------------------------------------------------------------------- #
{
    printf '\n===== HARDWARE =====\n'
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
    printf '\n===== MODEL CARD (HuggingFace) =====\n'
    HC="$(hf_candidates)"
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
        printf '\n----- llama-fit-params (parsed: ngl=%s ncmoe=%s ctx=%s) -----\n' \
            "${FIT_NGL:-?}" "${FIT_NCMOE:-?}" "${FIT_CTX:-?}"
        grep -iE 'fit|gpu_layers|cpu_moe|n_ctx|MiB|offload|memory' <<< "$FIT_LOG" | tail -n 25 || true
    fi
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
