#!/usr/bin/env bash
set -euo pipefail

# Pick from tmux buffer history with fzf and copy the selected buffer to the
# host/system clipboard. Never pastes into the active pane.

clipboard_helper=${TMUX_CLIPBOARD_HELPER:-$HOME/.config/tmux/scripts/tmux-copy-to-system-clipboard.sh}

if ! command -v fzf >/dev/null 2>&1; then
    tmux display-message 'fzf not found; cannot open tmux buffer picker'
    exit 127
fi

if ! tmux list-buffers >/dev/null 2>&1; then
    tmux display-message 'No tmux buffers to copy'
    exit 0
fi

buffer_count=$(tmux list-buffers | wc -l | tr -d '[:space:]')
if [[ ${buffer_count:-0} -eq 0 ]]; then
    tmux display-message 'No tmux buffers to copy'
    exit 0
fi

selected=$(
    tmux list-buffers -O creation -r -F '#{buffer_name}	#{buffer_size}	#{buffer_sample}' |
        fzf \
            --prompt='tmux buffer > ' \
            --layout=reverse \
            --delimiter=$'\t' \
            --with-nth=1,2,3 \
            --preview='tmux show-buffer -b {1}' \
            --preview-window='right:60%:wrap' \
            --no-multi
) || exit 0

[[ -n $selected ]] || exit 0

buffer_name=${selected%%$'\t'*}
if [[ -z $buffer_name ]]; then
    tmux display-message 'No tmux buffer selected'
    exit 0
fi

if tmux save-buffer -b "$buffer_name" - | "$clipboard_helper"; then
    tmux display-message "Copied tmux buffer $buffer_name to system clipboard"
else
    status=$?
    tmux display-message "Failed to copy tmux buffer $buffer_name to system clipboard"
    exit "$status"
fi
