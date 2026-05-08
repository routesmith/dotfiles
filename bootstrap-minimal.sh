#!/bin/sh
# bootstrap-minimal.sh — bring a fresh Debian/Ubuntu host to a usable
# minimal-dotfiles posture by installing apt baseline + chezmoi, then
# `chezmoi init --apply` against routesmith/dotfiles with a profile.
#
# Usage:
#   sh bootstrap-minimal.sh --profile {workstation|server-minimal|proxmox-host}
#
# Ad-hoc:
#   curl -fsSL https://raw.githubusercontent.com/routesmith/dotfiles/main/bootstrap-minimal.sh \
#     | sh -s -- --profile server-minimal
#
# Idempotent. Does not modify the chezmoi source tree.

set -eu

PROFILE="server-minimal"

while [ $# -gt 0 ]; do
  case "$1" in
    --profile)
      [ $# -ge 2 ] || { echo "--profile requires a value" >&2; exit 2; }
      PROFILE="$2"
      shift 2
      ;;
    --profile=*)
      PROFILE="${1#--profile=}"
      shift
      ;;
    -h|--help)
      sed -n '2,14p' "$0" 2>/dev/null || true
      exit 0
      ;;
    *)
      printf 'unknown argument: %s\n' "$1" >&2
      exit 2
      ;;
  esac
done

case "$PROFILE" in
  workstation|server-minimal|proxmox-host) : ;;
  *)
    printf 'invalid profile: %s (expected workstation|server-minimal|proxmox-host)\n' \
      "$PROFILE" >&2
    exit 2
    ;;
esac

if [ ! -r /etc/os-release ]; then
  echo 'cannot read /etc/os-release; refusing to run on unknown OS' >&2
  exit 1
fi
# shellcheck disable=SC1091
. /etc/os-release
case "${ID:-}" in
  debian|ubuntu) : ;;
  *)
    printf 'unsupported distro: %s (Debian/Ubuntu only for v1)\n' "${ID:-unknown}" >&2
    exit 1
    ;;
esac

if [ "$(id -u)" -eq 0 ]; then
  SUDO=""
elif command -v sudo >/dev/null 2>&1; then
  SUDO="sudo"
else
  echo 'must run as root or have sudo available' >&2
  exit 1
fi

PKGS_COMMON="zsh git curl ca-certificates tmux"
case "$PROFILE" in
  # Debian/Ubuntu rename `fd` to `fdfind` and `bat` to `batcat` to avoid
  # collisions with other packages. The `fd=fdfind` and `bat=batcat`
  # aliases in dot_zsh/aliases (Debian-conditional) make these resolve
  # by their canonical names; required because dot_zshrc uses `fd` and
  # `bat` unconditionally (FZF_DEFAULT_COMMAND, the `cat` alias, etc.).
  server-minimal) PKGS_EXTRA="fzf zoxide ripgrep bat fd-find" ;;
  workstation|proxmox-host) PKGS_EXTRA="" ;;
esac

printf '==> apt: installing baseline for profile=%s\n' "$PROFILE"
$SUDO apt-get update
# shellcheck disable=SC2086
$SUDO apt-get install -y $PKGS_COMMON $PKGS_EXTRA

mkdir -p "$HOME/.local/bin"
if [ ! -x "$HOME/.local/bin/chezmoi" ]; then
  echo '==> installing chezmoi to ~/.local/bin (apt version may be old)'
  curl -fsSL https://get.chezmoi.io | sh -s -- -b "$HOME/.local/bin"
else
  echo '==> chezmoi already installed at ~/.local/bin/chezmoi'
fi
CHEZMOI="$HOME/.local/bin/chezmoi"

printf '==> chezmoi init (profile=%s)\n' "$PROFILE"
"$CHEZMOI" init --no-tty --promptString "profile=$PROFILE" \
  routesmith/dotfiles

# init writes ~/.config/chezmoi/chezmoi.toml but does not reload its in-memory
# data context for this invocation, so .chezmoi.config.data.profile would be
# empty in the chezmoiignore/external templates if --apply ran in the same
# call. A second invocation reads the freshly-rendered config.
echo '==> chezmoi apply'
"$CHEZMOI" apply

ZSH_PATH=$(command -v zsh || true)
if [ -z "$ZSH_PATH" ]; then
  echo 'zsh not on PATH after install; aborting' >&2
  exit 1
fi
TARGET_USER="${USER:-$(id -un)}"
CURRENT_SHELL=$(getent passwd "$TARGET_USER" 2>/dev/null | cut -d: -f7)
if [ "$CURRENT_SHELL" != "$ZSH_PATH" ]; then
  printf '==> chsh: %s -> %s\n' "${CURRENT_SHELL:-unknown}" "$ZSH_PATH"
  if [ "$(id -u)" -eq 0 ]; then
    chsh -s "$ZSH_PATH" "$TARGET_USER"
  else
    $SUDO chsh -s "$ZSH_PATH" "$TARGET_USER"
  fi
else
  printf '==> login shell already %s\n' "$ZSH_PATH"
fi

echo '==> verifying DOTFILES_PROFILE'
RESOLVED=$(zsh -i -c 'print -r -- "$DOTFILES_PROFILE"' 2>/dev/null || true)
if [ "$RESOLVED" != "$PROFILE" ]; then
  printf 'DOTFILES_PROFILE check failed: got %s expected %s\n' \
    "${RESOLVED:-<empty>}" "$PROFILE" >&2
  exit 1
fi

printf 'bootstrap-minimal: ok (profile=%s)\n' "$PROFILE"
