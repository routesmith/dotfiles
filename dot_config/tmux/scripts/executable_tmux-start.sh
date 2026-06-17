#!/usr/bin/env bash
SESSION="workflow"
SCRIPT_DIR="$(dirname "$0")"

# Load window roles
source "$SCRIPT_DIR/tmux-windows.sh"

# Create session if it doesn't exist
if ! tmux has-session -t "$SESSION" 2>/dev/null; then
  for i in "${!TMUX_WINDOW_ROLE[@]}"; do
    [[ "$i" -eq 0 ]] && continue
    role="${TMUX_WINDOW_ROLE[$i]}"
    if [[ "$i" -eq 1 ]]; then
      tmux new-session -d -s "$SESSION" -n "$role"
    else
      tmux new-window -d -t "$SESSION:$i" -n "$role"
    fi
    tmux set-window-option -t "${SESSION}:$i" @role "$role"
  done
fi

tmux attach -t "$SESSION"
