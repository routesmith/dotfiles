#!/usr/bin/env bash
set -euo pipefail

# Build & install ImageMagick 7 from source into ~/.local (WSL/Ubuntu)
# Includes HEIC (libheif) + AVIF delegate support via libheif + codec libs.
#
# Usage:
#   update-imagemagick.sh              # builds latest main
#   IM_TAG=7.1.1-xx update-imagemagick.sh   # pin a specific tag
#   IM_PREFIX=~/.local update-imagemagick.sh
#
# Notes:
# - This script is intended for Ubuntu/WSL.
# - It does not remove/disable apt ImageMagick; it simply installs your own
#   `magick` into ~/.local/bin.

log() { printf "\n[%s] %s\n" "$(date '+%F %T')" "$*" >&2; }

: "${IM_PREFIX:=$HOME/.local}"
: "${IM_SRC_ROOT:=$HOME/src}"
: "${IM_REPO:=https://github.com/ImageMagick/ImageMagick.git}"
: "${IM_DIR:=$IM_SRC_ROOT/ImageMagick}"
: "${IM_TAG:=}" # e.g. "7.1.1-xx". Leave empty to use main.
: "${JOBS:=$(nproc)}"

# Basic sanity
if [[ ! -d /etc/apt ]]; then
    log "This doesn't look like a Debian/Ubuntu system (no /etc/apt)."
    log "If you're on macOS, just use: brew install imagemagick"
    exit 1
fi

log "Installing build dependencies (HEIC/AVIF delegates, plus common formats)..."
sudo apt update
sudo apt install -y \
    build-essential pkg-config git ca-certificates \
    libheif-dev libde265-dev libx265-dev libaom-dev \
    libjpeg-dev libpng-dev libtiff-dev libwebp-dev libopenexr-dev \
    liblcms2-dev libxml2-dev zlib1g-dev libzip-dev \
    libfreetype6-dev libfontconfig1-dev

# Optional but nice-to-have delegates (SVG/text shaping/PDF rasterization)
# Comment out if you don’t care.
sudo apt install -y \
    librsvg2-dev libpango1.0-dev ghostscript || true

mkdir -p "$IM_SRC_ROOT"

if [[ -d "$IM_DIR/.git" ]]; then
    log "Updating existing repo at: $IM_DIR"
    git -C "$IM_DIR" fetch --all --tags
else
    log "Cloning ImageMagick repo to: $IM_DIR"
    git clone "$IM_REPO" "$IM_DIR"
fi

cd "$IM_DIR"

if [[ -n "$IM_TAG" ]]; then
    log "Checking out tag: $IM_TAG"
    git checkout --force "refs/tags/$IM_TAG"
else
    log "Checking out latest main"
    git checkout --force main
    git pull --ff-only
fi

# Clean prior builds
log "Preparing build..."
if [[ -f Makefile ]]; then
    make distclean || true
fi

# Configure
log "Configuring (prefix=$IM_PREFIX)..."
./configure \
    --prefix="$IM_PREFIX" \
    --disable-static

log "Building (jobs=$JOBS)..."
make -j"$JOBS"

log "Installing into $IM_PREFIX ..."
make install

# Ensure ~/.local/bin is in PATH for this session
export PATH="$IM_PREFIX/bin:$PATH"

log "Verifying installation..."
if command -v magick >/dev/null 2>&1; then
    magick -version
else
    log "ERROR: 'magick' not found on PATH after install. Check $IM_PREFIX/bin."
    exit 2
fi

log "Checking delegate formats (HEIC/HEIF/AVIF should appear)..."
magick -list format | egrep -i 'heic|heif|avif' || {
    log "WARNING: HEIC/HEIF/AVIF not detected in 'magick -list format'."
    log "This usually means libheif delegate wasn't picked up."
    log "Check config.log in the build dir for 'heif' and 'aom/x265/de265'."
}

log "Done."
log "Tip: ensure PATH includes '$IM_PREFIX/bin' early in your shell startup:"
log "  export PATH=\"\$HOME/.local/bin:\$PATH\""
