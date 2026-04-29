#!/bin/bash

TARGET_DIR="$HOME/.claude"

printf "Copying settings.json to %s...\n" "$TARGET_DIR"
cp .claude/settings.json "$TARGET_DIR/settings.json"

printf "Copying settings.local.json to %s...\n" "$TARGET_DIR"
cp .claude/settings.local.json "$TARGET_DIR/settings.local.json"

printf "Copying mcp.json to %s...\n" "$TARGET_DIR"
cp .claude/mcp.json "$TARGET_DIR/mcp.json"

printf "Copying commands to %s/commands...\n" "$TARGET_DIR"
mkdir -p "$TARGET_DIR/commands"
cp -r .claude/commands/. "$TARGET_DIR/commands/"

printf "Copying skills to %s/skills...\n" "$TARGET_DIR"
mkdir -p "$TARGET_DIR/skills"
cp -r .claude/skills/. "$TARGET_DIR/skills/"

printf "Installation complete! Claude configuration updated successfully.\n"
