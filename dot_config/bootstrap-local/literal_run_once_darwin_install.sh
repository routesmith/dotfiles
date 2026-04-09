#!/bin/bash
set -e

echo "🔧 [macOS] Installing Homebrew packages..."

brew install \
    bat \
    chezmoi \
    clipper \
    delta \
    fd \
    git-delta \
    lsd \
    neovim \
    ripgrep \
    starship \
    tmux \
    tree-sitter \
    wget \
    zoxide \
    direnv \
    wezterm \
    lazygit \
    font-jetbrains-mono-nerd-font \
    font-hack-nerd-font \
    font-fira-code-nerd-font \
    font-fira-mono-nerd-font \
    glow \
    tree \
    ast-grep \
    yazi \
    1password-cli \
    lftp \
    renameutils \
    pstree \
    imagemagick \
    treesitter-cli \
    claude \
    koekeishiya/formulae/skhd \
    --cask raycast \
    --cask claude-code

echo "✅ [macOS] Homebrew packages installed."

if command -v cargo &>/dev/null; then
    echo "🔨 [macOS] Installing Cargo tools..."
    cargo install \
        atuin \
        navi \
        stylua
    echo "✅ [macOS] Cargo tools installed."
else
    echo "🚫 [macOS] Cargo not found — skipping Rust tool installs. Run 'rustup-init'."
fi
