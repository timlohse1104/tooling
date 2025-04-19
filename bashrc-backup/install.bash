#!/bin/bash

printf "Copy aliases to user's home directory...\n"
cp .bashrc-aliases ~/.bashrc-aliases

printf "Copy functions to user's home directory...\n"
cp .bashrc-functions ~/.bashrc-functions

# Check current ~/.bashrc for appearence of # CUSTOM START and # CUSTOM END and grep the lines between them into a variable
current_bashrc_custom_lines=$(grep -A 1000 -B 1000 -E '^# CUSTOM START|^- *# CUSTOM END' ~/.bashrc)

# Grep the lines between # CUSTOM START and # CUSTOM END in the .bashrc in this folder into a variable
new_bashrc_custom_lines=$(grep -A 1000 -B 1000 -E '^# CUSTOM START|^- *# CUSTOM END' .bashrc)

# Check if current_bashrc_custom_lines is not empty and set new_bashrc_custom_lines instead of current_bashrc_custom_lines in the ~/.bashrc file at the location of # CUSTOM START and # CUSTOM END
if [ -n "$current_bashrc_custom_lines" ]; then
    # Delete current_bashrc_custom_lines content from ~/.bashrc
    sed -i '/^# CUSTOM START/,/^# CUSTOM END/d' ~/.bashrc

    printf "Deleted old bashrc settings from ~/.bashrc.\n"
fi

# Append new_bashrc_custom_lines at the end of ~/.bashrc
echo "" >> ~/.bashrc
echo "$new_bashrc_custom_lines" >> ~/.bashrc

printf "Appended new bashrc settings to ~/.bashrc.\n"

# Source the .bashrc file to apply changes
printf "Installation complete! Bash configuration updated successfully.\n"
printf "See available aliases with 'aliases' and functions with 'functions'.\n"
exec bash -l
