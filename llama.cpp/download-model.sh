#!/usr/bin/env bash
#
# download-model.sh — fetch prebuilt GGUF files from HuggingFace into
# $LLAMA_MODELS_DIR (outside this repo; never committed).
#
# Prefers the 'hf' / 'huggingface-cli' tool (resume, auth); falls back to curl.
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
MANIFEST="$SCRIPT_DIR/models.list"

usage() {
    cat <<EOF
Usage:
  download-model.sh <repo_id> <filename> [dest_subdir]   Download one file
  download-model.sh --all                                Download every entry in models.list
  download-model.sh --list                               Show manifest entries
  download-model.sh --help

Target dir: \$LLAMA_MODELS_DIR = $LLAMA_MODELS_DIR
Gated models: set HF_TOKEN in config.env or run 'hf auth login'.
EOF
}

trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }

download_one() {
    local repo="$1" file="$2" dest="${3:-}"
    local target_dir target
    if [[ -n "$dest" ]]; then
        target_dir="$LLAMA_MODELS_DIR/$dest"
    else
        target_dir="$LLAMA_MODELS_DIR"
    fi
    mkdir -p "$target_dir"
    target="$target_dir/$(basename "$file")"

    if [[ -s "$target" ]]; then
        printf '  SKIP (exists): %s\n' "$target"
        return 0
    fi

    printf '  GET %s :: %s -> %s\n' "$repo" "$file" "$target_dir"

    local -a auth=()
    if command -v hf >/dev/null 2>&1; then
        [[ -n "${HF_TOKEN:-}" ]] && auth=(--token "$HF_TOKEN")
        hf download "$repo" "$file" --local-dir "$target_dir" "${auth[@]}"
    elif command -v huggingface-cli >/dev/null 2>&1; then
        [[ -n "${HF_TOKEN:-}" ]] && auth=(--token "$HF_TOKEN")
        huggingface-cli download "$repo" "$file" --local-dir "$target_dir" "${auth[@]}"
    else
        local -a hdr=()
        [[ -n "${HF_TOKEN:-}" ]] && hdr=(-H "Authorization: Bearer $HF_TOKEN")
        curl -L --fail -C - "${hdr[@]}" -o "$target" \
            "https://huggingface.co/${repo}/resolve/main/${file}"
    fi
}

download_all() {
    [[ -f "$MANIFEST" ]] || { printf 'No manifest: %s\n' "$MANIFEST" >&2; exit 1; }
    printf 'Downloading all entries from %s\n' "$MANIFEST"
    local line repo file dest
    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line//[[:space:]]/}" ]] && continue
        IFS='|' read -r repo file dest <<< "$line"
        repo="$(trim "$repo")"; file="$(trim "$file")"; dest="$(trim "${dest:-}")"
        if [[ -z "$repo" || -z "$file" ]]; then
            printf '  WARN: skipping malformed line: %s\n' "$line" >&2
            continue
        fi
        download_one "$repo" "$file" "$dest"
    done < "$MANIFEST"
}

case "${1:-}" in
    ""|-h|--help) usage ;;
    --list)
        [[ -f "$MANIFEST" ]] || { printf 'No manifest: %s\n' "$MANIFEST" >&2; exit 1; }
        grep -vE '^[[:space:]]*(#|$)' "$MANIFEST" || true
        ;;
    --all) download_all ;;
    --*)   printf 'Unknown option: %s\n' "$1" >&2; usage; exit 1 ;;
    *)
        [[ $# -ge 2 ]] || { usage; exit 1; }
        download_one "$1" "$2" "${3:-}"
        ;;
esac
