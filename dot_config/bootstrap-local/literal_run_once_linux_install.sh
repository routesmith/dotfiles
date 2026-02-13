#!/bin/bash
set -e

echo "🔧 [Linux] Installing APT packages..."
sudo apt update
sudo apt install -y \
    bat \
    build-essential \
    curl \
    git \
    gnupg2 \
    lsd \
    neovim \
    ripgrep \
    tmux \
    unzip \
    wget \
    xclip \
    zsh \
    tree \
    direnv

echo "✅ [Linux] APT packages installed."

if command -v cargo &>/dev/null; then
    echo "🔨 [Linux] Installing Cargo tools..."
    cargo install \
        atuin \
        delta \
        fd-find \
        navi \
        starship \
        stylua \
        yazi \
        zoxide
    echo "✅ [Linux] Cargo tools installed."
else
    echo "🚫 [Linux] Cargo not found — skipping Rust tool installs. Run 'rustup-init'."
fi
