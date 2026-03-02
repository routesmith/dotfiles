#!/usr/bin/env bash
# Purpose: Show where each tool is sourced from in WSL (apt, asdf, cargo, etc.)

TOOLS=(
    chezmoi git curl wget 7z fd rg bat delta fzf btop zoxide glow lsd starship
    nvim lazygit wezterm python python3 node npm go rustc cargo restic rclone
    jq yq just task watchexec entr tokei dog navi gh glab kubectl helm k9s
    terraform terragrunt vault deno asdf
)

echo -e "🔍 Tool Origin Lookup (WSL)\n"

for tool in "${TOOLS[@]}"; do
    BIN_PATH=$(command -v "$tool" 2>/dev/null)
    if [[ -n "$BIN_PATH" ]]; then
        echo -e "$tool\t→ $BIN_PATH"
    else
        echo -e "$tool\t→ ❌ Not Found"
    fi
done
