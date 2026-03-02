#!/usr/bin/env bash
set -euo pipefail

# Restic updater for WSL (and Linux generally)
# Installs into ~/.local/bin/restic
# Default pins to 0.18.1 (match Windows), but allows explicit versions.

DEFAULT_VER="0.18.1"
OWNER="restic"
REPO="restic"
ARCH="linux_amd64"

BIN_DIR="${HOME}/.local/bin"
BIN="${BIN_DIR}/restic"

usage() {
    cat <<EOF
Usage:
  update-restic.sh                Install default version (${DEFAULT_VER})
  update-restic.sh <version>      Install a specific version (e.g. 0.18.1)
  update-restic.sh --latest       Install latest via restic self-update (after install)
  update-restic.sh --where        Show restic path + version
EOF
}

need() { command -v "$1" >/dev/null 2>&1 || {
    echo "Missing dependency: $1"
    exit 1
}; }

install_ver() {
    local ver="$1"
    mkdir -p "$BIN_DIR"

    local tmp
    tmp="$(mktemp -d)"
    trap '[ -n "${tmp-}" ] && rm -rf "${tmp}"' EXIT

    echo "Installing restic v${ver} -> ${BIN}"
    curl -fsSLo "${tmp}/restic.bz2" \
        "https://github.com/${OWNER}/${REPO}/releases/download/v${ver}/restic_${ver}_${ARCH}.bz2"

    bunzip2 -f "${tmp}/restic.bz2"
    chmod +x "${tmp}/restic"
    mv -f "${tmp}/restic" "${BIN}"

    "${BIN}" version
}

show_where() {
    if command -v restic >/dev/null 2>&1; then
        command -v restic
        restic version
    else
        echo "restic not installed"
        exit 1
    fi
}

main() {
    need curl
    need bunzip2

    case "${1:-}" in
    "")
        install_ver "${DEFAULT_VER}"
        ;;
    "--where")
        show_where
        ;;
    "--latest")
        # Ensure installed first, then use restic's own updater
        if ! command -v restic >/dev/null 2>&1; then
            install_ver "${DEFAULT_VER}"
        fi
        restic self-update
        restic version
        ;;
    "-h" | "--help")
        usage
        ;;
    *)
        install_ver "$1"
        ;;
    esac
}

main "$@"
