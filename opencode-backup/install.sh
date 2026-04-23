#!/bin/bash

TARGET_DIR="$HOME/.config/opencode"
TARGET_FILE="$TARGET_DIR/opencode.jsonc"

if [ ! -d "$TARGET_DIR" ]; then
    printf "Creating directory %s...\n" "$TARGET_DIR"
    mkdir -p "$TARGET_DIR"
fi

printf "Copying opencode.jsonc to %s...\n" "$TARGET_FILE"
cp opencode.jsonc "$TARGET_FILE"

printf "Installation complete! opencode configuration updated successfully.\n"
