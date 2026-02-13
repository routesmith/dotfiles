#!/usr/bin/env bash

set -euo pipefail

OUTDIR=~/test-area/project-snapshot/$(uname | tr '[:upper:]' '[:lower:]')
mkdir -p "$OUTDIR"

echo "🔧 Saving environment snapshot to: $OUTDIR"

# 1. System Info & Toolchain
{
    echo "# uname"
    uname -a
    echo

    echo "# Shell"
    echo "$SHELL"
    command -v zsh && zsh --version
    echo

    echo "# Locale"
    locale || true
    echo

    echo "# Python"
    command -v python3 && python3 --version
    echo

    echo "# Neovim"
    command -v nvim && nvim --version | head -n 1
    echo

    echo "# Starship"
    command -v starship && starship --version
    echo

    echo "# FZF"
    command -v fzf && fzf --version
    echo

    echo "# chezmoi template identity (core fields)"
    chezmoi data | jq '{os, arch, username, hostname, homeDir, chezmoi: .chezmoi.sourceDir}'
} >"$OUTDIR/env-summary.txt"

# 2. chezmoi
chezmoi managed >"$OUTDIR/chezmoi-managed.txt"
chezmoi dump-config | jq . >"$OUTDIR/chezmoi-config-dump.json"
chezmoi data | jq . >"$OUTDIR/chezmoi-template-data.json"
chezmoi diff >"$OUTDIR/chezmoi-diff.txt"

# 3. Neovim healthcheck
nvim --headless "+checkhealth" +qall >"$OUTDIR/nvim-health.txt" || echo "(nvim checkhealth failed)" >"$OUTDIR/nvim-health.txt"

# 4. Python venv packages
if [[ -n "${VIRTUAL_ENV:-}" ]]; then
    pip list --format=freeze >"$OUTDIR/venv-packages.txt"
else
    echo "(no active virtualenv)" >"$OUTDIR/venv-packages.txt"
fi

# 5. System Package Manager
if command -v brew &>/dev/null; then
    brew list >"$OUTDIR/packages.txt"
elif command -v apt &>/dev/null; then
    apt list --installed 2>/dev/null | grep -v "^Listing..." >"$OUTDIR/packages.txt"
else
    echo "(no brew or apt found)" >"$OUTDIR/packages.txt"
fi

# 6. Zsh plugin summary
if [ -d ~/.zsh/plugins ]; then
    ls ~/.zsh/plugins >"$OUTDIR/zsh-plugins.txt"
else
    echo "(~/.zsh/plugins not found)" >"$OUTDIR/zsh-plugins.txt"
fi

echo "✅ Snapshot complete."
