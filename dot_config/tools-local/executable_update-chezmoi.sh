#!/usr/bin/env bash
set -euo pipefail

# Build chezmoi from a local git checkout into ~/go/bin.
# Defaults to ~/src/chezmoi, matching the local source mirror.

CHEZMOI_SRC="${CHEZMOI_SRC:-$HOME/src/chezmoi}"
CHEZMOI_BIN_DIR="${CHEZMOI_BIN_DIR:-$HOME/go/bin}"
CHEZMOI_REPO="${CHEZMOI_REPO:-https://github.com/twpayne/chezmoi.git}"
CHEZMOI_BRANCH="${CHEZMOI_BRANCH:-master}"
INSTALL_TARGET="$CHEZMOI_BIN_DIR/chezmoi"

usage() {
    cat <<EOF
Usage:
  update-chezmoi.sh          Report and build chezmoi if source has updates
  update-chezmoi.sh --check  Report current/candidate versions only

Environment:
  CHEZMOI_SRC=~/src/chezmoi  chezmoi git checkout
  CHEZMOI_BIN_DIR=~/go/bin   install directory
  CHEZMOI_REPO=$CHEZMOI_REPO
                              clone URL when CHEZMOI_SRC is missing
  CHEZMOI_BRANCH=master      remote branch to track
  FORCE=1                    rebuild even when source is current
EOF
}

need_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "Missing dependency: $1" >&2
        exit 1
    fi
}

ensure_source() {
    if [[ -d "$CHEZMOI_SRC/.git" ]]; then
        return
    fi

    if [[ -e "$CHEZMOI_SRC" ]]; then
        echo "$CHEZMOI_SRC exists but is not a git checkout. Exiting." >&2
        exit 1
    fi

    echo "Cloning chezmoi source to $CHEZMOI_SRC"
    mkdir -p "$(dirname "$CHEZMOI_SRC")"
    git clone --branch "$CHEZMOI_BRANCH" "$CHEZMOI_REPO" "$CHEZMOI_SRC"
}

fetch_candidate() {
    git -C "$CHEZMOI_SRC" fetch --tags origin "$CHEZMOI_BRANCH"
}

describe_rev() {
    git -C "$CHEZMOI_SRC" describe --tags --always "$1"
}

current_installed_version() {
    if [[ -x "$INSTALL_TARGET" ]]; then
        "$INSTALL_TARGET" --version | awk 'NR == 1 {gsub(/,/, "", $3); print $3}'
    elif command -v chezmoi >/dev/null 2>&1; then
        chezmoi --version | awk 'NR == 1 {gsub(/,/, "", $3); print $3}'
    fi
}

current_installed_commit() {
    local version_output

    if [[ -x "$INSTALL_TARGET" ]]; then
        version_output="$("$INSTALL_TARGET" --version)"
    elif command -v chezmoi >/dev/null 2>&1; then
        version_output="$(chezmoi --version)"
    else
        return 0
    fi

    sed -n 's/.* commit \([^,]*\),.*/\1/p' <<<"$version_output"
}

ensure_clean_checkout() {
    if ! git -C "$CHEZMOI_SRC" diff --quiet || ! git -C "$CHEZMOI_SRC" diff --cached --quiet; then
        echo "$CHEZMOI_SRC has uncommitted changes; refusing to update the source checkout." >&2
        exit 1
    fi
}

report_update() {
    local installed_version="$1"
    local installed_commit="$2"
    local current_source="$3"
    local candidate_source="$4"
    local current_rev="$5"
    local candidate_rev="$6"

    echo "Current installed chezmoi: ${installed_version:-not found}"
    echo "Current installed commit: ${installed_commit:-not found}"
    echo "Current source revision: $current_source ($current_rev)"
    echo "Candidate source revision: $candidate_source ($candidate_rev)"

    if [[ -z "$installed_version" ]]; then
        echo "Update selected: chezmoi is not installed at the expected prefix"
        return 0
    fi

    if [[ "$current_rev" == "$candidate_rev" && "$installed_commit" == "$candidate_rev"* && "${FORCE:-0}" != "1" ]]; then
        echo "No update selected: installed chezmoi and source checkout are current"
        return 1
    fi

    if [[ "$current_rev" == "$candidate_rev" && "${FORCE:-0}" != "1" ]]; then
        echo "Update selected: installed chezmoi does not match current source"
        return 0
    fi

    echo "Update selected: $current_source -> $candidate_source"
    return 0
}

build_and_install() {
    need_cmd git
    need_cmd go
    need_cmd make
    need_cmd install

    cd "$CHEZMOI_SRC"
    ensure_clean_checkout
    git checkout "$CHEZMOI_BRANCH"
    git merge --ff-only "origin/$CHEZMOI_BRANCH"

    make build-in-git-working-copy
    mkdir -p "$(dirname "$INSTALL_TARGET")"
    install -m 0755 chezmoi "$INSTALL_TARGET"

    "$INSTALL_TARGET" --version
}

main() {
    case "${1:-}" in
    -h | --help)
        usage
        ;;
    --check | "")
        ensure_source
        fetch_candidate

        current_rev="$(git -C "$CHEZMOI_SRC" rev-parse HEAD)"
        candidate_rev="$(git -C "$CHEZMOI_SRC" rev-parse "origin/$CHEZMOI_BRANCH")"
        current_source="$(describe_rev "$current_rev")"
        candidate_source="$(describe_rev "$candidate_rev")"

        if ! report_update "$(current_installed_version || true)" "$(current_installed_commit || true)" "$current_source" "$candidate_source" "${current_rev:0:12}" "${candidate_rev:0:12}"; then
            exit 0
        fi

        [[ "${1:-}" == "--check" ]] && exit 0
        build_and_install
        ;;
    *)
        usage >&2
        exit 2
        ;;
    esac
}

main "$@"
