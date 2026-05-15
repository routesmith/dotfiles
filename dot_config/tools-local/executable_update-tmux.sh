#!/usr/bin/env bash
set -euo pipefail

# Build tmux from a local git checkout into ~/.local.
# Defaults to ~/src/tmux, matching the local source mirror.

TMUX_SRC="${TMUX_SRC:-$HOME/src/tmux}"
TMUX_PREFIX="${TMUX_PREFIX:-$HOME/.local}"
TMUX_REPO="${TMUX_REPO:-https://github.com/tmux/tmux.git}"
TMUX_BRANCH="${TMUX_BRANCH:-master}"

if command -v nproc >/dev/null 2>&1; then
    JOBS="${JOBS:-$(nproc)}"
elif [[ "$(uname -s)" == "Darwin" ]]; then
    JOBS="${JOBS:-$(sysctl -n hw.ncpu)}"
else
    JOBS="${JOBS:-4}"
fi

usage() {
    cat <<EOF
Usage:
  update-tmux.sh          Report and build tmux if the source checkout has updates
  update-tmux.sh --check  Report current/candidate versions only

Environment:
  TMUX_SRC=~/src/tmux     tmux git checkout
  TMUX_PREFIX=~/.local    install prefix
  TMUX_REPO=$TMUX_REPO
                          clone URL when TMUX_SRC is missing
  TMUX_BRANCH=master      remote branch to track
  JOBS=$JOBS              parallel make jobs
  FORCE=1                 rebuild even when source is current
EOF
}

need_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "Missing dependency: $1" >&2
        exit 1
    fi
}

ensure_source() {
    if [[ -d "$TMUX_SRC/.git" ]]; then
        return
    fi

    if [[ -e "$TMUX_SRC" ]]; then
        echo "$TMUX_SRC exists but is not a git checkout. Exiting." >&2
        exit 1
    fi

    echo "Cloning tmux source to $TMUX_SRC"
    mkdir -p "$(dirname "$TMUX_SRC")"
    git clone --branch "$TMUX_BRANCH" "$TMUX_REPO" "$TMUX_SRC"
}

current_installed_version() {
    if [[ -x "$TMUX_PREFIX/bin/tmux" ]]; then
        "$TMUX_PREFIX/bin/tmux" -V | awk '{print $2}'
    elif command -v tmux >/dev/null 2>&1; then
        tmux -V | awk '{print $2}'
    fi
}

describe_rev() {
    git -C "$TMUX_SRC" describe --tags --always "$1"
}

tmux_version_for_rev() {
    git -C "$TMUX_SRC" show "$1:configure.ac" |
        sed -n 's/^AC_INIT(\[tmux\], *\([^)]*\)).*/\1/p' |
        head -n 1
}

fetch_candidate() {
    git -C "$TMUX_SRC" fetch --tags origin "$TMUX_BRANCH"
}

ensure_clean_checkout() {
    if ! git -C "$TMUX_SRC" diff --quiet || ! git -C "$TMUX_SRC" diff --cached --quiet; then
        echo "$TMUX_SRC has uncommitted changes; refusing to update the source checkout." >&2
        exit 1
    fi
}

report_update() {
    local current_installed="$1"
    local current_version="$2"
    local current_source="$3"
    local candidate_version="$4"
    local candidate_source="$5"
    local current_rev="$6"
    local candidate_rev="$7"

    echo "Current installed tmux: ${current_installed:-not found}"
    echo "Current source tmux version: $current_version"
    echo "Current source revision: $current_source ($current_rev)"
    echo "Candidate source tmux version: $candidate_version"
    echo "Candidate source revision: $candidate_source ($candidate_rev)"

    if [[ -z "$current_installed" ]]; then
        echo "Update selected: tmux is not installed at the expected prefix"
        return 0
    fi

    if [[ "$current_rev" == "$candidate_rev" && "${FORCE:-0}" != "1" ]]; then
        echo "No update selected: source checkout is current"
        return 1
    fi

    echo "Update selected: $current_source -> $candidate_source"
    return 0
}

print_dependency_hint() {
    case "$(uname -s)" in
    Linux)
        if [[ -d /etc/apt ]]; then
            echo "Dependency hint: sudo apt install build-essential autoconf automake bison pkg-config libevent-dev libncurses-dev"
        fi
        ;;
    Darwin)
        echo "Dependency hint: brew install autoconf automake bison pkg-config libevent ncurses"
        ;;
    esac
}

build_and_install() {
    need_cmd git
    need_cmd sh
    need_cmd make

    cd "$TMUX_SRC"
    ensure_clean_checkout
    git checkout "$TMUX_BRANCH"
    git merge --ff-only "origin/$TMUX_BRANCH"

    print_dependency_hint

    sh autogen.sh
    ./configure --prefix="$TMUX_PREFIX"
    make -j"$JOBS"
    make install

    "$TMUX_PREFIX/bin/tmux" -V
}

main() {
    case "${1:-}" in
    -h | --help)
        usage
        ;;
    --check | "")
        ensure_source
        fetch_candidate

        local current_rev candidate_rev current_version candidate_version current_source candidate_source
        current_rev="$(git -C "$TMUX_SRC" rev-parse HEAD)"
        candidate_rev="$(git -C "$TMUX_SRC" rev-parse "origin/$TMUX_BRANCH")"
        current_version="$(tmux_version_for_rev "$current_rev")"
        candidate_version="$(tmux_version_for_rev "$candidate_rev")"
        current_source="$(describe_rev "$current_rev")"
        candidate_source="$(describe_rev "$candidate_rev")"

        if ! report_update "$(current_installed_version || true)" "$current_version" "$current_source" "$candidate_version" "$candidate_source" "${current_rev:0:12}" "${candidate_rev:0:12}"; then
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
