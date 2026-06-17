#!/usr/bin/env zsh
# Interactive FZF theme picker and previewer

setopt EXTENDED_GLOB

local colors_dir="${ZSH_COLOR_DIR:-$HOME/test-area/colors/scripts}"

if [[ ! -d "$colors_dir" ]]; then
    echo "Error: Theme directory not found: $colors_dir" >&2
    return 1
fi

# Full path to your preview script
local preview_script="$HOME/.config/tools-local/preview_color_theme.zsh"

if [[ ! -x "$preview_script" ]]; then
    echo "Error: Preview script not found or not executable: $preview_script" >&2
    return 1
fi

# Launch fzf to choose a theme
local selected
selected=$(find "$colors_dir" -type f -name '*.sh' | sed -E 's|.*/||; s/\.sh$//' | sort |
    fzf --preview="$preview_script {}" \
        --prompt="Theme > " \
        --preview-window=right:wrap)

if [[ -n "$selected" ]]; then
    "$preview_script" "$selected"
fi
