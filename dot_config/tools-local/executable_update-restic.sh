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
  update-restic.sh --check        Report installed/default-pinned versions only
  update-restic.sh --latest --check
                                  Report installed/latest upstream versions only
EOF
}

need() { command -v "$1" >/dev/null 2>&1 || {
    echo "Missing dependency: $1"
    exit 1
}; }

current_installed_version() {
    if [[ -x "$BIN" ]]; then
        "$BIN" version | awk 'NR == 1 {print $2}'
    elif command -v restic >/dev/null 2>&1; then
        restic version | awk 'NR == 1 {print $2}'
    fi
}

latest_release_version() {
    curl -fsSL "https://api.github.com/repos/${OWNER}/${REPO}/releases/latest" |
        sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"v\{0,1\}\([^"]*\)".*/\1/p' |
        head -n 1
}

report_update() {
    local current="$1"
    local target="$2"
    local mode="$3"

    echo "Current installed restic: ${current:-not found}"
    echo "Target restic ($mode): $target"

    if [[ "$current" == "$target" ]]; then
        echo "No update selected: installed restic already matches target"
        return 1
    fi

    echo "Update selected: ${current:-not found} -> $target"
    return 0
}

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
        if report_update "$(current_installed_version || true)" "${DEFAULT_VER}" "default pin"; then
            install_ver "${DEFAULT_VER}"
        fi
        ;;
    "--check")
        report_update "$(current_installed_version || true)" "${DEFAULT_VER}" "default pin" || true
        ;;
    "--where")
        show_where
        ;;
    "--latest")
        if [[ "${2:-}" == "--check" ]]; then
            report_update "$(current_installed_version || true)" "$(latest_release_version)" "latest upstream" || true
            exit 0
        fi
        # Ensure installed first, then use restic's own updater
        if ! command -v restic >/dev/null 2>&1; then
            install_ver "${DEFAULT_VER}"
        fi
        report_update "$(current_installed_version || true)" "$(latest_release_version)" "latest upstream" || exit 0
        restic self-update
        restic version
        ;;
    "-h" | "--help")
        usage
        ;;
    *)
        if [[ "${2:-}" == "--check" ]]; then
            report_update "$(current_installed_version || true)" "$1" "explicit" || true
            exit 0
        fi
        if report_update "$(current_installed_version || true)" "$1" "explicit"; then
            install_ver "$1"
        fi
        ;;
    esac
}

main "$@"
