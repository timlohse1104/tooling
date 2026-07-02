#!/usr/bin/env bash
#
# bootstrap.sh — install a prebuilt Vulkan llama.cpp into ./vendor
#
# Linux/Pop!_OS adaptation of countzero/windows_llama.cpp's rebuild_llama.cpp.ps1:
# instead of compiling, fetch the official prebuilt Vulkan release tarball.
# No compiler, no CMake, no conda.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- load config -----------------------------------------------------------
if [[ -f "$SCRIPT_DIR/config.env" ]]; then
    # shellcheck source=/dev/null
    source "$SCRIPT_DIR/config.env"
elif [[ -f "$SCRIPT_DIR/config.env.example" ]]; then
    printf 'config.env not found — using defaults from config.env.example\n' >&2
    # shellcheck source=/dev/null
    source "$SCRIPT_DIR/config.env.example"
fi

LLAMA_VERSION="${LLAMA_VERSION:-latest}"
VENDOR_DIR="$SCRIPT_DIR/vendor/llama.cpp"
CACHE_DIR="$SCRIPT_DIR/cache"
MARKER="$SCRIPT_DIR/vendor/.llama-version"

# --- args ------------------------------------------------------------------
FORCE=0
for arg in "$@"; do
    case "$arg" in
        -f|--force) FORCE=1 ;;
        -h|--help)
            cat <<EOF
Usage: bootstrap.sh [--force]

Installs the prebuilt Vulkan llama.cpp release defined by LLAMA_VERSION
(config.env) into ./vendor/llama.cpp. Use --force to reinstall the same tag.
EOF
            exit 0 ;;
        *) printf 'Unknown argument: %s\n' "$arg" >&2; exit 1 ;;
    esac
done

# --- helpers ---------------------------------------------------------------
log() { printf '\033[33m%s\033[0m\n' "$*"; }

install_apt_deps() {
    local deps=(curl ca-certificates tar jq libvulkan1 mesa-vulkan-drivers vulkan-tools libgomp1 libcurl4)
    local missing=() pkg
    for pkg in "${deps[@]}"; do
        dpkg -s "$pkg" >/dev/null 2>&1 || missing+=("$pkg")
    done
    if [[ ${#missing[@]} -eq 0 ]]; then
        printf '  all dependencies present\n'
        return
    fi
    printf '  installing: %s\n' "${missing[*]}"
    sudo apt-get update
    sudo apt-get install -y "${missing[@]}"
}

resolve_tag() {
    if [[ "$LLAMA_VERSION" == "latest" ]]; then
        curl -fsSL https://api.github.com/repos/ggml-org/llama.cpp/releases/latest \
            | jq -r '.tag_name'
    else
        printf '%s' "$LLAMA_VERSION"
    fi
}

detect_arch() {
    case "$(uname -m)" in
        x86_64)        printf 'x64' ;;
        aarch64|arm64) printf 'arm64' ;;
        *) printf 'ERROR: unsupported architecture: %s\n' "$(uname -m)" >&2; exit 1 ;;
    esac
}

# --- run -------------------------------------------------------------------
log "[1/5] Installing APT runtime dependencies..."
install_apt_deps

log "[2/5] Resolving llama.cpp release..."
TAG="$(resolve_tag)"
[[ -n "$TAG" && "$TAG" != "null" ]] || { printf 'ERROR: could not resolve release tag\n' >&2; exit 1; }
ARCH="$(detect_arch)"
ASSET="llama-${TAG}-bin-ubuntu-vulkan-${ARCH}.tar.gz"
URL="https://github.com/ggml-org/llama.cpp/releases/download/${TAG}/${ASSET}"
printf '  version=%s  arch=%s\n' "$TAG" "$ARCH"

if [[ "$FORCE" != "1" && -f "$MARKER" && "$(cat "$MARKER")" == "$TAG" ]] \
   && find "$SCRIPT_DIR/vendor" -name llama-server -type f -print -quit 2>/dev/null | grep -q .; then
    log "[3/5] Already installed ($TAG) — skipping download (use --force to reinstall)."
else
    log "[3/5] Downloading + extracting $ASSET ..."
    mkdir -p "$CACHE_DIR"
    curl -L --fail -C - -o "$CACHE_DIR/$ASSET" "$URL"
    rm -rf "$VENDOR_DIR"
    mkdir -p "$VENDOR_DIR"
    tar -xzf "$CACHE_DIR/$ASSET" -C "$VENDOR_DIR"
    printf '%s' "$TAG" > "$MARKER"
fi

log "[4/5] Locating binaries..."
BIN_PATH="$(find "$SCRIPT_DIR/vendor" -name llama-server -type f 2>/dev/null | head -n1)"
[[ -n "$BIN_PATH" ]] || { printf 'ERROR: llama-server not found after extraction\n' >&2; exit 1; }
BIN_DIR="$(dirname "$BIN_PATH")"
chmod +x "$BIN_DIR"/llama-* 2>/dev/null || true
printf '  bin dir: %s\n' "$BIN_DIR"

log "[5/5] Verifying..."
if ! LD_LIBRARY_PATH="$BIN_DIR:${LD_LIBRARY_PATH:-}" "$BIN_PATH" --version; then
    printf 'ERROR: llama-server failed to run (possible glibc mismatch — see README troubleshooting)\n' >&2
    exit 1
fi
if command -v vulkaninfo >/dev/null 2>&1; then
    if vulkaninfo --summary >/dev/null 2>&1; then
        printf '  Vulkan: OK (GPU visible)\n'
    else
        printf '  WARNING: vulkaninfo found no usable GPU; llama.cpp will fall back to CPU\n' >&2
    fi
fi

log "Done. Start the server with: ./server.sh"
