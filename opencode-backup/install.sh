#!/bin/bash

TARGET_DIR="$HOME/.config/opencode"
TARGET_FILE="$TARGET_DIR/opencode.jsonc"
AGENTS_SRC_DIR="agents"
AGENTS_TARGET_DIR="$TARGET_DIR/agents"
SKILLS_SRC_DIR="skills"
SKILLS_TARGET_DIR="$TARGET_DIR/skills"

if [ ! -d "$TARGET_DIR" ]; then
    printf "Creating directory %s...\n" "$TARGET_DIR"
    mkdir -p "$TARGET_DIR"
fi

printf "Copying opencode.jsonc to %s...\n" "$TARGET_FILE"
cp opencode.jsonc "$TARGET_FILE"

if [ -d "$AGENTS_SRC_DIR" ] && compgen -G "$AGENTS_SRC_DIR/*.md" > /dev/null; then
    printf "Syncing agents to %s...\n" "$AGENTS_TARGET_DIR"
    rm -rf "$AGENTS_TARGET_DIR"
    mkdir -p "$AGENTS_TARGET_DIR"
    cp "$AGENTS_SRC_DIR"/*.md "$AGENTS_TARGET_DIR"/
fi

if [ -d "$SKILLS_SRC_DIR" ]; then
    printf "Syncing skills to %s...\n" "$SKILLS_TARGET_DIR"
    rm -rf "$SKILLS_TARGET_DIR"
    mkdir -p "$SKILLS_TARGET_DIR"
    cp -R "$SKILLS_SRC_DIR"/. "$SKILLS_TARGET_DIR"/
fi

printf "Installation complete! opencode configuration updated successfully.\n"
