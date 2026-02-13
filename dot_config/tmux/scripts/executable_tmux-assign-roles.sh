#!/usr/bin/env bash

# Assigns a role based on the workflow layout, only really needs to be done
# after recreating a destroyed window in the workflow.

SESSION="${SESSION:-workflow}"
SCRIPT_DIR="$(dirname "$0")"
source "$SCRIPT_DIR/tmux-windows.sh"

for i in "${!TMUX_WINDOW_ROLE[@]}"; do
  role="${TMUX_WINDOW_ROLE[$i]}"
  [[ -z "$role" ]] && continue

  current_name=$(tmux list-windows -t "$SESSION" -F "#{window_index}:#{window_name}" | grep "^$i:" | cut -d: -f2-)
  
  if [[ "$current_name" != "$role" ]]; then
    tmux rename-window -t "${SESSION}:$i" "$role"
  fi
done

