#!/usr/bin/env bash
set -euo pipefail

# Build & install ImageMagick 7 from source into ~/.local (WSL/Ubuntu)
# Includes HEIC (libheif) + AVIF delegate support via libheif + codec libs.
#
# Usage:
#   update-imagemagick.sh              # builds latest main
#   update-imagemagick.sh --check      # report current/candidate only
#   update-imagemagick.sh --rollback   # roll back to pre-update revision and rebuild
#   IM_TAG=7.1.1-xx update-imagemagick.sh   # pin a specific tag
#   IM_PREFIX=~/.local update-imagemagick.sh
#   FORCE=1 update-imagemagick.sh      # rebuild even when source is current
#
# Notes:
# - Dependency installation is automatic on Debian/Ubuntu/WSL. On macOS,
#   install build dependencies with Homebrew before running this script.
# - It does not remove/disable apt ImageMagick; it simply installs your own
#   `magick` into ~/.local/bin.

log() { printf "\n[%s] %s\n" "$(date '+%F %T')" "$*" >&2; }

: "${IM_PREFIX:=$HOME/.local}"
: "${IM_SRC_ROOT:=$HOME/src}"
: "${IM_REPO:=https://github.com/ImageMagick/ImageMagick.git}"
: "${IM_DIR:=$IM_SRC_ROOT/ImageMagick}"
: "${IM_TAG:=}" # e.g. "7.1.1-xx". Leave empty to use main.
: "${IM_BRANCH:=main}"

if command -v nproc >/dev/null 2>&1; then
    : "${JOBS:=$(nproc)}"
elif [[ "$(uname -s)" == "Darwin" ]]; then
    : "${JOBS:=$(sysctl -n hw.ncpu)}"
else
    : "${JOBS:=4}"
fi

PREV_REV_FILE="$IM_DIR/.prev-rev"

usage() {
    cat <<EOF
Usage:
  update-imagemagick.sh            Report and build ImageMagick if source has updates
  update-imagemagick.sh --check    Report current/candidate versions only
  update-imagemagick.sh --rollback Roll back to pre-update revision and rebuild

Environment:
  IM_TAG=7.1.1-xx                Build a specific tag instead of ${IM_BRANCH}
  IM_PREFIX=~/.local             Install prefix
  FORCE=1                        Rebuild even when source is current
EOF
}

current_installed_version() {
    if [[ -x "$IM_PREFIX/bin/magick" ]]; then
        "$IM_PREFIX/bin/magick" -version | awk 'NR == 1 {print $3}'
    elif command -v magick >/dev/null 2>&1; then
        magick -version | awk 'NR == 1 {print $3}'
    fi
}

ensure_source() {
    mkdir -p "$IM_SRC_ROOT"

    if [[ -d "$IM_DIR/.git" ]]; then
        log "Fetching ImageMagick metadata at: $IM_DIR"
        git -C "$IM_DIR" fetch --all --tags
    else
        log "Cloning ImageMagick repo to: $IM_DIR"
        git clone "$IM_REPO" "$IM_DIR"
    fi
}

target_ref() {
    if [[ -n "$IM_TAG" ]]; then
        printf 'refs/tags/%s\n' "$IM_TAG"
    else
        printf 'origin/%s\n' "$IM_BRANCH"
    fi
}

describe_rev() {
    git -C "$IM_DIR" describe --tags --always "$1"
}

report_update() {
    local current_installed="$1"
    local current_source="$2"
    local candidate_source="$3"
    local current_rev="$4"
    local candidate_rev="$5"

    echo "Current installed ImageMagick: ${current_installed:-not found}"
    echo "Current source ImageMagick: $current_source ($current_rev)"
    echo "Candidate source ImageMagick: $candidate_source ($candidate_rev)"

    if [[ -z "$current_installed" ]]; then
        echo "Update selected: ImageMagick is not installed at the expected prefix"
        return 0
    fi

    if [[ "$current_rev" == "$candidate_rev" && "${FORCE:-0}" != "1" ]]; then
        echo "No update selected: source checkout is current"
        return 1
    fi

    echo "Update selected: $current_source -> $candidate_source"
    return 0
}

install_build_deps() {
    case "$(uname -s)" in
    Linux)
        if [[ ! -d /etc/apt ]]; then
            log "This Linux system does not have /etc/apt; install ImageMagick build dependencies manually."
            return
        fi

        log "Installing build dependencies (HEIC/AVIF delegates, plus common formats)..."
        sudo apt update
        sudo apt install -y \
            build-essential pkg-config git ca-certificates \
            libheif-dev libde265-dev libx265-dev libaom-dev \
            libjpeg-dev libpng-dev libtiff-dev libwebp-dev libopenexr-dev \
            liblcms2-dev libxml2-dev zlib1g-dev libzip-dev \
            libfreetype6-dev libfontconfig1-dev

        sudo apt install -y \
            librsvg2-dev libpango1.0-dev ghostscript || true
        ;;
    Darwin)
        log "macOS detected; expecting dependencies from Homebrew."
        log "If configure fails, run: brew install pkg-config libheif jpeg libpng libtiff webp openexr little-cms2 libxml2 zlib libzip freetype fontconfig"
        ;;
    *)
        log "Unsupported OS for dependency hints: $(uname -s)"
        ;;
    esac
}

save_prev_state() {
    git -C "$IM_DIR" rev-parse HEAD > "$PREV_REV_FILE"
}

build_and_install() {
    log "Preparing build..."
    if [[ -f Makefile ]]; then
        make distclean || true
    fi

    log "Configuring (prefix=$IM_PREFIX)..."
    ./configure \
        --prefix="$IM_PREFIX" \
        --disable-static

    log "Building (jobs=$JOBS)..."
    make -j"$JOBS"

    log "Installing into $IM_PREFIX ..."
    make install

    export PATH="$IM_PREFIX/bin:$PATH"

    log "Verifying installation..."
    if command -v magick >/dev/null 2>&1; then
        magick -version
    else
        log "ERROR: 'magick' not found on PATH after install. Check $IM_PREFIX/bin."
        exit 2
    fi
}

rollback() {
    if [[ ! -r "$PREV_REV_FILE" ]]; then
        echo "No rollback state found at $PREV_REV_FILE" >&2
        echo "No previous revision was saved; cannot rollback." >&2
        exit 1
    fi

    local prev_rev
    prev_rev="$(cat "$PREV_REV_FILE")"

    if [[ -z "$prev_rev" ]]; then
        echo "Rollback state file $PREV_REV_FILE is empty." >&2
        exit 1
    fi

    log "Rolling back ImageMagick to revision ${prev_rev:0:12}"

    cd "$IM_DIR"

    if ! git -C "$IM_DIR" diff --quiet || ! git -C "$IM_DIR" diff --cached --quiet; then
        echo "$IM_DIR has uncommitted changes; refusing to rollback." >&2
        exit 1
    fi

    git checkout --force "$prev_rev"

    local rolled_back_version
    rolled_back_version="$(describe_rev HEAD)"
    log "Rebuilding ImageMagick $rolled_back_version from ${prev_rev:0:12}..."

    build_and_install

    log "Checking delegate formats (HEIC/HEIF/AVIF should appear)..."
    magick -list format | egrep -i 'heic|heif|avif' || {
        log "WARNING: HEIC/HEIF/AVIF not detected in 'magick -list format'."
        log "This usually means libheif delegate wasn't picked up."
        log "Check config.log in the build dir for 'heif' and 'aom/x265/de265'."
    }

    log "Rollback complete: ImageMagick $(magick -version 2>/dev/null | head -1 || echo 'unknown')"
    log "Rolled back to: ${prev_rev:0:12} ($rolled_back_version)"
}

main() {
    case "${1:-}" in
    -h | --help)
        usage
        ;;
    --rollback)
        rollback
        ;;
    --check | "")
        ensure_source

        local current_rev candidate_rev current_source candidate_source ref
        ref="$(target_ref)"
        current_rev="$(git -C "$IM_DIR" rev-parse HEAD)"
        candidate_rev="$(git -C "$IM_DIR" rev-parse "$ref")"
        current_source="$(describe_rev "$current_rev")"
        candidate_source="$(describe_rev "$candidate_rev")"

        if ! report_update "$(current_installed_version || true)" "$current_source" "$candidate_source" "${current_rev:0:12}" "${candidate_rev:0:12}"; then
            [[ "${1:-}" == "--check" ]] && exit 0
            exit 0
        fi

        [[ "${1:-}" == "--check" ]] && exit 0

        install_build_deps

        cd "$IM_DIR"
        save_prev_state

        if [[ -n "$IM_TAG" ]]; then
            log "Checking out tag: $IM_TAG"
            git checkout --force "refs/tags/$IM_TAG"
        else
            log "Checking out latest $IM_BRANCH"
            git checkout "$IM_BRANCH"
            git merge --ff-only "origin/$IM_BRANCH"
        fi

        build_and_install

        log "Checking delegate formats (HEIC/HEIF/AVIF should appear)..."
        magick -list format | egrep -i 'heic|heif|avif' || {
            log "WARNING: HEIC/HEIF/AVIF not detected in 'magick -list format'."
            log "This usually means libheif delegate wasn't picked up."
            log "Check config.log in the build dir for 'heif' and 'aom/x265/de265'."
        }

        log "Done."
        log "Tip: ensure PATH includes '$IM_PREFIX/bin' early in your shell startup:"
        log "  export PATH=\"\$HOME/.local/bin:\$PATH\""
        ;;
    *)
        usage >&2
        exit 2
        ;;
    esac
}

main "$@"
