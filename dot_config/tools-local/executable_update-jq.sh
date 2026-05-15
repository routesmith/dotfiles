#!/usr/bin/env bash

set -euo pipefail

JQ_SRC="${JQ_SRC:-$HOME/src/jq}"
JQ_INSTALL_PREFIX="${JQ_INSTALL_PREFIX:-$HOME/.local}"
JQ_REPO="${JQ_REPO:-https://github.com/jqlang/jq.git}"
JQ_BRANCH="${JQ_BRANCH:-master}"
JOBS="${JOBS:-8}"

usage() {
    cat <<EOF
Usage:
  update-jq.sh          Report and build jq if the source checkout has updates
  update-jq.sh --check  Report current/candidate versions only

Environment:
  JQ_REPO=$JQ_REPO
                          clone URL when JQ_SRC is missing
  JQ_BRANCH=master      Remote branch to track
  JOBS=8                Parallel make jobs
  FORCE=1               Rebuild even when source is current
EOF
}

ensure_source() {
    if [[ -d "$JQ_SRC/.git" ]]; then
        return
    fi

    if [[ -e "$JQ_SRC" ]]; then
        echo "$JQ_SRC exists but is not a git checkout. Exiting." >&2
        exit 1
    fi

    echo "Cloning jq source to $JQ_SRC"
    mkdir -p "$(dirname "$JQ_SRC")"
    git clone --branch "$JQ_BRANCH" "$JQ_REPO" "$JQ_SRC"
}

current_installed_version() {
    if [[ -x "$JQ_INSTALL_PREFIX/bin/jq" ]]; then
        "$JQ_INSTALL_PREFIX/bin/jq" --version | sed 's/^jq-//'
    elif command -v jq >/dev/null 2>&1; then
        jq --version | sed 's/^jq-//'
    fi
}

describe_rev() {
    git -C "$JQ_SRC" describe --tags --always "$1" | sed 's/^jq-//'
}

fetch_candidate() {
    git -C "$JQ_SRC" fetch --tags origin "$JQ_BRANCH"
}

report_update() {
    local current_installed="$1"
    local current_source="$2"
    local candidate_source="$3"
    local current_rev="$4"
    local candidate_rev="$5"

    echo "Current installed jq: ${current_installed:-not found}"
    echo "Current source jq: $current_source ($current_rev)"
    echo "Candidate source jq: $candidate_source ($candidate_rev)"

    if [[ -z "$current_installed" ]]; then
        echo "Update selected: jq is not installed at the expected prefix"
        return 0
    fi

    if [[ "$current_rev" == "$candidate_rev" && "${FORCE:-0}" != "1" ]]; then
        echo "No update selected: source checkout is current"
        return 1
    fi

    echo "Update selected: $current_source -> $candidate_source"
    return 0
}

main() {
    case "${1:-}" in
    -h | --help)
        usage
        ;;
    --check | "")
        ensure_source
        fetch_candidate

        local current_rev candidate_rev current_source candidate_source
        current_rev="$(git -C "$JQ_SRC" rev-parse HEAD)"
        candidate_rev="$(git -C "$JQ_SRC" rev-parse "origin/$JQ_BRANCH")"
        current_source="$(describe_rev "$current_rev")"
        candidate_source="$(describe_rev "$candidate_rev")"

        if ! report_update "$(current_installed_version || true)" "$current_source" "$candidate_source" "${current_rev:0:12}" "${candidate_rev:0:12}"; then
            [[ "${1:-}" == "--check" ]] && exit 0
            exit 0
        fi

        [[ "${1:-}" == "--check" ]] && exit 0

        cd "$JQ_SRC"
        git merge --ff-only "origin/$JQ_BRANCH"
        git submodule update --init
        echo "Building jq $candidate_source..."
        autoreconf -i
        ./configure --with-oniguruma=builtin --prefix="$JQ_INSTALL_PREFIX"
        make clean
        make -j"$JOBS"
        make check
        make install PREFIX="$JQ_INSTALL_PREFIX"
        echo "Installed jq $candidate_source to $JQ_INSTALL_PREFIX/bin"
        ;;
    *)
        usage >&2
        exit 2
        ;;
    esac
}

main "$@"
