#!/usr/bin/env bash

set -euo pipefail

NVIM_PREFIX="$HOME/neovim"
SRC_ROOT="$HOME/src"
REPO="https://github.com/neovim/neovim.git"
TMP_CLONE="$SRC_ROOT/neovim-stable-tmp"

echo "🌐 Cloning Neovim stable branch into temp dir..."
rm -rf "$TMP_CLONE"
git clone --depth=1 --branch=stable "$REPO" "$TMP_CLONE"

cd "$TMP_CLONE"
VERSION=$(git describe --tags)
VERSION_CLEAN="${VERSION#v}"
CLONE_DIR="$SRC_ROOT/neovim-$VERSION_CLEAN"

if [[ -d "$CLONE_DIR" ]]; then
    echo "✅ Already have $CLONE_DIR — skipping build."
else
    echo "🚚 Moving stable source to $CLONE_DIR"
    mv "$TMP_CLONE" "$CLONE_DIR"
    cd "$CLONE_DIR"

    echo "🛠️ Building Neovim $VERSION_CLEAN..."
    rm -rf build/
    make CMAKE_EXTRA_FLAGS="-DCMAKE_INSTALL_PREFIX=$NVIM_PREFIX"
    make install

    # Optional: update symlink
    ln -snf "$CLONE_DIR" "$SRC_ROOT/neovim"

    echo "✅ Installed Neovim $VERSION_CLEAN to $NVIM_PREFIX"
fi
