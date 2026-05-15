#!/usr/bin/env bash

set -euo pipefail

NVIM_PREFIX="$HOME/neovim"
SRC_ROOT="$HOME/src"
REPO="https://github.com/neovim/neovim.git"
TMP_CLONE="$SRC_ROOT/neovim-stable-tmp"

usage() {
    cat <<EOF
Usage:
  update-nvim.sh          Report and install latest stable Neovim if needed
  update-nvim.sh --check  Report current/candidate versions only

Environment:
  FORCE=1                 Rebuild even when the source directory exists
EOF
}

current_installed_version() {
    if [[ -x "$NVIM_PREFIX/bin/nvim" ]]; then
        "$NVIM_PREFIX/bin/nvim" --version | awk 'NR == 1 {sub(/^v/, "", $2); print $2}'
    elif command -v nvim >/dev/null 2>&1; then
        nvim --version | awk 'NR == 1 {sub(/^v/, "", $2); print $2}'
    fi
}

fetch_candidate_source() {
    echo "🌐 Cloning Neovim stable branch into temp dir..."
    mkdir -p "$SRC_ROOT"
    rm -rf "$TMP_CLONE"
    git clone --depth=1 --branch=stable "$REPO" "$TMP_CLONE"
}

candidate_version() {
    git -C "$TMP_CLONE" describe --tags | sed 's/^v//'
}

report_update() {
    local current="$1"
    local candidate="$2"
    local clone_dir="$3"

    echo "Current installed Neovim: ${current:-not found}"
    echo "Candidate stable Neovim: $candidate"

    if [[ -d "$clone_dir" && "${FORCE:-0}" != "1" ]]; then
        echo "No update selected: source directory already exists at $clone_dir"
        return 1
    fi

    if [[ "$current" == "$candidate" && "${FORCE:-0}" != "1" ]]; then
        echo "No update selected: installed Neovim already reports $candidate"
        return 1
    fi

    echo "Update selected: ${current:-not found} -> $candidate"
    return 0
}

main() {
    case "${1:-}" in
    --check)
        fetch_candidate_source
        local version_clean
        version_clean="$(candidate_version)"
        report_update "$(current_installed_version || true)" "$version_clean" "$SRC_ROOT/neovim-$version_clean" || true
        rm -rf "$TMP_CLONE"
        ;;
    -h | --help)
        usage
        ;;
    "")
        fetch_candidate_source
        local version_clean clone_dir
        version_clean="$(candidate_version)"
        clone_dir="$SRC_ROOT/neovim-$version_clean"

        if ! report_update "$(current_installed_version || true)" "$version_clean" "$clone_dir"; then
            rm -rf "$TMP_CLONE"
            exit 0
        fi

        echo "🚚 Moving stable source to $clone_dir"
        rm -rf "$clone_dir"
        mv "$TMP_CLONE" "$clone_dir"
        cd "$clone_dir"

        echo "🛠️ Building Neovim $version_clean..."
        rm -rf build/
        make CMAKE_EXTRA_FLAGS="-DCMAKE_INSTALL_PREFIX=$NVIM_PREFIX"
        make install

        ln -snf "$clone_dir" "$SRC_ROOT/neovim"

        echo "✅ Installed Neovim $version_clean to $NVIM_PREFIX"
        ;;
    *)
        usage >&2
        exit 2
        ;;
    esac
}

main "$@"
