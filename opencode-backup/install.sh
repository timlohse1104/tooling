#!/bin/bash

TARGET_DIR="$HOME/.config/opencode"
TARGET_FILE="$TARGET_DIR/opencode.jsonc"
AGENTS_SRC_DIR="agents"
AGENTS_TARGET_DIR="$TARGET_DIR/agents"

if [ ! -d "$TARGET_DIR" ]; then
    printf "Creating directory %s...\n" "$TARGET_DIR"
    mkdir -p "$TARGET_DIR"
fi

printf "Copying opencode.jsonc to %s...\n" "$TARGET_FILE"
cp opencode.jsonc "$TARGET_FILE"

if [ -d "$AGENTS_SRC_DIR" ]; then
    printf "Syncing agents to %s...\n" "$AGENTS_TARGET_DIR"
    rm -rf "$AGENTS_TARGET_DIR"
    mkdir -p "$AGENTS_TARGET_DIR"
    cp "$AGENTS_SRC_DIR"/*.md "$AGENTS_TARGET_DIR"/
fi

printf "Installation complete! opencode configuration updated successfully.\n"
