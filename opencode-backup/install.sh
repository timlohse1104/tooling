#!/bin/bash
# ============================================================
# OpenCode personal-config installer (add-only).
#
# Copies this backup's personal opencode.jsonc, agents/ and skills/
# into ~/.config/opencode/ WITHOUT removing anything already there.
# Other sources (e.g. the C4 team installer) may have installed their
# own agents/skills/plugins/scripts alongside these — this script must
# never wipe them. Files this script would overwrite are backed up first.
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DIR="$HOME/.config/opencode"
TARGET_FILE="$TARGET_DIR/opencode.jsonc"
AGENTS_SRC_DIR="$SCRIPT_DIR/agents"
AGENTS_TARGET_DIR="$TARGET_DIR/agents"
SKILLS_SRC_DIR="$SCRIPT_DIR/skills"
SKILLS_TARGET_DIR="$TARGET_DIR/skills"
PLUGIN_SRC_DIR="$SCRIPT_DIR/plugin"
PLUGIN_TARGET_DIR="$TARGET_DIR/plugin"

mkdir -p "$TARGET_DIR"

# Back up an existing destination file before it gets overwritten.
backup_if_exists() {
    local f="$1"
    [ -f "$f" ] || return 0
    local b="${f}.bak.$(date +%Y%m%d_%H%M%S)"
    cp "$f" "$b"
    printf "  Backup: %s\n" "$b"
}

# Copy a single file into place, backing up any existing target first.
install_file() {
    local src="$1" dst="$2"
    mkdir -p "$(dirname "$dst")"
    backup_if_exists "$dst"
    cp "$src" "$dst"
    printf "  Installed: %s\n" "$dst"
}

printf "Installing personal opencode.jsonc -> %s\n" "$TARGET_FILE"
install_file "$SCRIPT_DIR/opencode.jsonc" "$TARGET_FILE"

# Add agent definitions without deleting agents from other sources.
if [ -d "$AGENTS_SRC_DIR" ] && compgen -G "$AGENTS_SRC_DIR/*.md" > /dev/null; then
    printf "Adding agents to %s (existing files kept)...\n" "$AGENTS_TARGET_DIR"
    for f in "$AGENTS_SRC_DIR"/*.md; do
        install_file "$f" "$AGENTS_TARGET_DIR/$(basename "$f")"
    done
fi

# Add skills without deleting skills from other sources.
if [ -d "$SKILLS_SRC_DIR" ]; then
    printf "Adding skills to %s (existing skills kept)...\n" "$SKILLS_TARGET_DIR"
    shopt -s nullglob
    for skill_dir in "$SKILLS_SRC_DIR"/*/; do
        name="$(basename "$skill_dir")"
        printf "  Skill: %s\n" "$name"
        # Copy the skill's contents in without removing the target dir, so a
        # skill of the same name is updated file-by-file (backing up changed
        # files) rather than wiped-and-replaced.
        while IFS= read -r -d '' src; do
            rel="${src#"$skill_dir"}"
            install_file "$src" "$SKILLS_TARGET_DIR/$name/$rel"
        done < <(find "$skill_dir" -type f -print0)
    done
    shopt -u nullglob
fi

# Add plugins (auto-loaded from ~/.config/opencode/plugin/*.js) without
# deleting plugins from other sources (e.g. the C4 team's prod-guard.js).
# The command-guard rule file is only installed if the target does not already
# exist, so local rule customisations survive re-running the installer; the
# .js is always refreshed (backing up the previous version).
if [ -d "$PLUGIN_SRC_DIR" ]; then
    printf "Adding plugins to %s (existing files kept)...\n" "$PLUGIN_TARGET_DIR"
    shopt -s nullglob
    for src in "$PLUGIN_SRC_DIR"/*.js; do
        install_file "$src" "$PLUGIN_TARGET_DIR/$(basename "$src")"
    done
    for src in "$PLUGIN_SRC_DIR"/*.rules.json; do
        dst="$PLUGIN_TARGET_DIR/$(basename "$src")"
        if [ -f "$dst" ]; then
            printf "  Kept existing rules (not overwritten): %s\n" "$dst"
        else
            install_file "$src" "$dst"
        fi
    done
    shopt -u nullglob
fi

printf "Installation complete! opencode configuration updated (add-only).\n"
