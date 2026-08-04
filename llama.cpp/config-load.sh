# shellcheck shell=bash
#
# config-load.sh — resolve LLAMA_* settings for the bash tooling.
# Source it, don't execute it:  source "$SCRIPT_DIR/config-load.sh"
#
# Precedence, strongest first: an exported env var, config.env, the Windows
# host's config.ps1, config.env.example. The .example must come last — it
# assigns values unconditionally and would otherwise clobber both an exported
# value and the host's real one.
#
# Two bugs this file exists to fix, both hit on the Windows host:
#   * config.env.example carries CRLF. `source` then fails on every line
#     ("$'\r': command not found"), which took out server.sh, download-model.sh
#     and bootstrap.sh completely — they only had config.env / config.env.example
#     in their chain, and config.env does not exist there.
#   * That host configures itself in config.ps1, where LLAMA_BACKEND=cuda and
#     LLAMA_HOST=0.0.0.0. Falling through to the .example instead would fetch a
#     Vulkan build and bind the loopback address.

_llama_source_cfg() {
    local f="$1" tmp
    tmp="$(mktemp)"
    tr -d '\r' < "$f" > "$tmp"
    # shellcheck disable=SC1090
    source "$tmp"
    rm -f "$tmp"
}

# Expand PowerShell's $env:NAME via cmd.exe, so "$env:LOCALAPPDATA\llama.cpp"
# resolves the same way it does for the .ps1 scripts.
_llama_expand_env_refs() {
    local v="$1" name val
    while [[ "$v" =~ \$env:([A-Za-z_][A-Za-z0-9_]*) ]]; do
        name="${BASH_REMATCH[1]}"
        command -v cmd.exe >/dev/null 2>&1 || return 1
        # </dev/null matters: this runs inside a `while read` loop in
        # _llama_source_ps1, and cmd.exe would otherwise consume the remaining
        # config lines from stdin — silently dropping every setting after the
        # first one that needs expanding.
        val="$(cd / && cmd.exe /c "echo %${name}%" </dev/null 2>/dev/null | tr -d '\r\n')"
        [[ -n "$val" && "$val" != "%${name}%" ]] || return 1
        v="${v//\$env:$name/$val}"
    done
    printf '%s\n' "$v"
}

# C:\Users\x -> /mnt/c/Users/x, so a path from the Windows config works in WSL.
_llama_to_posix_path() {
    local v="${1//\\//}"
    [[ "$v" =~ ^([A-Za-z]):/(.*)$ ]] && v="/mnt/${BASH_REMATCH[1],,}/${BASH_REMATCH[2]}"
    printf '%s\n' "$v"
}

# config.ps1 is PowerShell, not bash, so it cannot be sourced. Read every
# `$NAME = "value"` assignment out of it instead.
_llama_source_ps1() {
    local file="$1" name value
    while read -r name value; do
        case "$name" in
            LLAMA_MODELS_DIR|LLAMA_PRESET)
                value="$(_llama_expand_env_refs "$value")" || {
                    printf 'config.ps1: cannot expand %s=%s — export it or create config.env\n' \
                        "$name" "$value" >&2
                    continue
                }
                value="$(_llama_to_posix_path "$value")"
                ;;
        esac
        printf -v "$name" '%s' "$value" 2>/dev/null || eval "$name=\$value"
    done < <(
        tr -d '\r' < "$file" \
        | sed -n 's/^[[:space:]]*\$\(LLAMA_[A-Z_0-9]*\|HF_TOKEN\)[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1 \2/p'
    )
}

_llama_load_config() {
    local dir="$1"
    local env_models_dir="${LLAMA_MODELS_DIR:-}" env_preset="${LLAMA_PRESET:-}"

    if [[ -f "$dir/config.env" ]]; then
        _llama_source_cfg "$dir/config.env"
    elif [[ -f "$dir/config.ps1" ]]; then
        _llama_source_ps1 "$dir/config.ps1"
    elif [[ -f "$dir/config.env.example" ]]; then
        printf 'config.env not found — using defaults from config.env.example\n' >&2
        _llama_source_cfg "$dir/config.env.example"
    fi

    [[ -n "$env_models_dir" ]] && LLAMA_MODELS_DIR="$env_models_dir"
    [[ -n "$env_preset" ]] && LLAMA_PRESET="$env_preset"
    return 0
}
