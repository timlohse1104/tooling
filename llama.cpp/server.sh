#!/usr/bin/env bash
#
# server.sh — start llama-server in router mode (default) or for a single model.
#
# Linux adaptation of countzero/windows_llama.cpp's examples/server.ps1. Heavy
# per-model tuning lives in the preset INI; this script stays portable.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -f "$SCRIPT_DIR/config.env" ]]; then
    # shellcheck source=/dev/null
    source "$SCRIPT_DIR/config.env"
elif [[ -f "$SCRIPT_DIR/config.env.example" ]]; then
    # shellcheck source=/dev/null
    source "$SCRIPT_DIR/config.env.example"
fi

LLAMA_MODELS_DIR="${LLAMA_MODELS_DIR:-$HOME/.local/share/llama.cpp/models}"
LLAMA_HOST="${LLAMA_HOST:-127.0.0.1}"
LLAMA_PORT="${LLAMA_PORT:-8081}"
LLAMA_PRESET="${LLAMA_PRESET:-presets/models.ini}"
LLAMA_MODELS_MAX="${LLAMA_MODELS_MAX:-1}"
LLAMA_NGL="${LLAMA_NGL:-999}"
LLAMA_CTX="${LLAMA_CTX:-0}"
LLAMA_KV="${LLAMA_KV:-f16}"

# --- locate binary (only when actually serving) ----------------------------
BIN=""
resolve_bin() {
    BIN="$(find "$SCRIPT_DIR/vendor" -name llama-server -type f 2>/dev/null | head -n1)"
    [[ -n "$BIN" ]] || { printf 'llama-server not found. Run ./bootstrap.sh first.\n' >&2; exit 1; }
    export LD_LIBRARY_PATH="$(dirname "$BIN"):${LD_LIBRARY_PATH:-}"
}

physical_cores() {
    local cps sockets
    if command -v lscpu >/dev/null 2>&1; then
        cps="$(lscpu | sed -n 's/^Core(s) per socket:[[:space:]]*//p')"
        sockets="$(lscpu | sed -n 's/^Socket(s):[[:space:]]*//p')"
        if [[ "$cps" =~ ^[0-9]+$ && "$sockets" =~ ^[0-9]+$ ]]; then
            printf '%s' "$(( cps * sockets ))"
            return
        fi
    fi
    nproc
}

list_models() {
    printf 'GGUF models under %s:\n' "$LLAMA_MODELS_DIR"
    if [[ -d "$LLAMA_MODELS_DIR" ]]; then
        find "$LLAMA_MODELS_DIR" -type f -name '*.gguf' \
            ! -name 'mmproj.*' ! -name 'ggml-vocab-*' 2>/dev/null | sort || true
    fi
}

run_router() {
    local preset="$SCRIPT_DIR/$LLAMA_PRESET"
    if [[ ! -f "$preset" ]]; then
        printf 'Preset not found: %s\n' "$preset" >&2
        printf 'Copy presets/models.example.ini to %s and edit the paths.\n' "$LLAMA_PRESET" >&2
        exit 1
    fi
    resolve_bin
    printf 'Router mode @ http://%s:%s  (preset: %s, max: %s)\n' \
        "$LLAMA_HOST" "$LLAMA_PORT" "$LLAMA_PRESET" "$LLAMA_MODELS_MAX"
    exec "$BIN" \
        --host "$LLAMA_HOST" \
        --port "$LLAMA_PORT" \
        --models-dir "$LLAMA_MODELS_DIR" \
        --models-preset "$preset" \
        --models-max "$LLAMA_MODELS_MAX"
}

run_single() {
    local model="$1"; shift || true
    [[ -f "$model" ]] || { printf 'Model not found: %s\n' "$model" >&2; exit 1; }
    resolve_bin
    local threads; threads="$(physical_cores)"
    local -a args=(
        --host "$LLAMA_HOST"
        --port "$LLAMA_PORT"
        --model "$model"
        --alias "$(basename "$model")"
        --threads "$threads"
        --n-gpu-layers "$LLAMA_NGL"
        --ctx-size "$LLAMA_CTX"
        --cache-type-k "$LLAMA_KV"
        --cache-type-v "$LLAMA_KV"
    )
    # mmproj autodetect (multimodal projector next to the model file)
    local mmproj
    mmproj="$(find "$(dirname "$model")" -maxdepth 1 -type f -name 'mmproj.*' 2>/dev/null | head -n1)"
    [[ -n "$mmproj" ]] && args+=(--mmproj "$mmproj")
    # passthrough of any extra llama-server flags
    args+=("$@")
    printf 'Single model @ http://%s:%s  (%s, threads=%s)\n' \
        "$LLAMA_HOST" "$LLAMA_PORT" "$(basename "$model")" "$threads"
    exec "$BIN" "${args[@]}"
}

case "${1:-}" in
    -h|--help)
        cat <<EOF
Usage:
  server.sh                       Router mode (multi-model) via \$LLAMA_PRESET
  server.sh <model.gguf> [args]   Single model; extra args pass through to llama-server
  server.sh --list                List GGUF files under \$LLAMA_MODELS_DIR
EOF
        ;;
    --list) list_models ;;
    "")     run_router ;;
    *)      run_single "$@" ;;
esac
