#!/usr/bin/env bash
# Drive a Hermes version upgrade across all four installs and report the
# before/after per host so silent drift can't hide again — the 2026-07-22
# failure was docker + macos sitting 2 weeks behind while every local run
# reported success without ever naming a host or a version.
#
# Scope is versions only. Model/routing config is the other tool:
# `hermes-fleet-config --report|--apply` (same targets, different job).
set -uo pipefail

FULL_UPDATE="$HOME/.config/tools-local/hermes_update_full.sh"
TARGETS_FILE="$HOME/.config/tools-local/hermes-fleet-targets.local.json"
HERMES_REMOTE="$HOME/.zsh/bin/hermes-remote"
ANSIBLE_UPDATE="$HOME/git/homelab-ansible/scripts/update-hermes.sh"
PWSH="/mnt/c/Program Files/PowerShell/7/pwsh.exe"

TARGETS="wsl windows macos docker"
usage() { echo "usage: $(basename "$0") [-n|--dry-run] [--target wsl|windows|macos|docker]" >&2; exit 2; }

# This script is a controller: it only means anything on a host that can reach
# every install. chezmoi distributes it everywhere, but the targets file is
# gitignored, so its presence is what marks a host as the controller. Without
# this guard the jq calls below fail non-fatally and the run emits a table of
# confident nonsense (a macOS host reporting itself as "(WSL2)").
if [ ! -r "$TARGETS_FILE" ]; then
    echo "$(basename "$0"): $TARGETS_FILE not found — this host is not configured" >&2
    echo "as a fleet controller. Nothing to do." >&2
    exit 3
fi

DRY_RUN=""
ONLY=""
# A loop, not a case on $1: flags combine, and getting this wrong means
# --dry-run is silently ignored and the run mutates the fleet.
while [ $# -gt 0 ]; do
    case "$1" in
        -n|--dry-run) DRY_RUN=1 ;;
        --target)     ONLY="${2:-}"; [ -n "$ONLY" ] || usage
                      [[ " $TARGETS " == *" $ONLY "* ]] || { echo "unknown target: $ONLY" >&2; usage; }
                      shift ;;
        *)            usage ;;
    esac
    shift
done
MACOS_HOST=$(jq -r '.macos.ssh_host' "$TARGETS_FILE")
DOCKER_HOST=$(jq -r '.docker.ssh_host' "$TARGETS_FILE")

# Short names for display: strip the user@ and the .internal suffix.
macos_short="${MACOS_HOST#*@}"; macos_short="${macos_short%%.*}"
docker_short="${DOCKER_HOST%%.*}"

# The whole point of this script: every line of output says which machine it is
# about. Target names are the internal handles; these are the machines. Derived,
# never literal — hostnames are operator-identifying and this repo is public, so
# the local names come from uname and the remote ones from the .local targets
# file. Portable too: this script is chezmoi-distributed to every workstation.
this_host=$(uname -n)
declare -A HOSTNAME_OF=(
    [wsl]="$this_host (WSL2)"
    [windows]="$this_host (Windows)"
    [macos]="$macos_short"
    [docker]="$docker_short"
)
declare -A METHOD_OF=([wsl]="git" [windows]="git" [macos]="git" [docker]="docker image")

if [ -t 1 ]; then
    B=$(tput bold); D=$(tput dim); R=$(tput sgr0)
    GREEN=$(tput setaf 2); YELLOW=$(tput setaf 3); RED=$(tput setaf 1)
else
    B=""; D=""; R=""; GREEN=""; YELLOW=""; RED=""
fi

rule() { printf '%s%s%s\n' "$D" "$(printf '─%.0s' {1..78})" "$R"; }

# ponytail: one grep, not a parser. Every install prints the same provenance
# line; anything else (host down, venv broken) falls through to "unreachable",
# which is the only distinction that changes what you do next.
version_of() {
    case "$1" in
        wsl)     hermes version 2>/dev/null ;;
        windows) "$PWSH" -NoProfile -NonInteractive -Command \
                     '& "$env:LOCALAPPDATA\hermes\hermes-agent\venv\Scripts\hermes.exe" version' 2>/dev/null ;;
        macos)   ssh -o ConnectTimeout=15 "$MACOS_HOST" 'zsh -lic "hermes version"' 2>/dev/null ;;
        docker)  "$HERMES_REMOTE" version </dev/null 2>/dev/null ;;
    esac | grep -m1 '^Hermes Agent' || echo "unreachable"
}

# "Hermes Agent v0.19.0 (2026.7.20) · upstream deadb43c · local 5a47f952 (+1…)"
#   -> "v0.19.0 (2026.7.20)  up:deadb43c  local:5a47f952"
# Keep the local sha: on the carried-branch hosts it is what is actually checked
# out, and upstream==origin/main tip alone would call a stranded host current.
short() {
    [ "$1" = "unreachable" ] && { printf 'unreachable'; return; }
    printf '%s' "$1" | sed -E '
        s/^Hermes Agent //
        s/ · upstream /  up:/
        s/ · local /  local:/
        s/ \(\+[0-9]+ carried commits?\)//'
}

upgrade() {
    case "$1" in
        wsl)     "$FULL_UPDATE" ;;
        # Windows carries no local commits, so plain `hermes update` is the
        # whole job — no branch reapply, no ui-tui build, no systemd units.
        windows) "$PWSH" -NoProfile -NonInteractive -Command \
                     '& "$env:LOCALAPPDATA\hermes\hermes-agent\venv\Scripts\hermes.exe" update' ;;
        # Same script, already on the macOS host via chezmoi — but macOS homes
        # live under /Users, not /home, so the path must stay unexpanded until
        # the remote shell resolves it. zsh -lic: non-login ssh has no Homebrew
        # PATH.
        macos)   ssh "$MACOS_HOST" 'zsh -lic "~/.config/tools-local/hermes_update_full.sh"' ;;
        # docker-host-01 is Ansible-owned, so this defers to the sanctioned
        # deploy path rather than driving Compose directly: update-hermes.sh
        # does the disk-space guard, OCI provenance capture, and post-deploy
        # smoke tests that a bare `compose pull && up -d` skips.
        docker)  "$ANSIBLE_UPDATE" ;;
    esac
}

selected() { [ -z "$ONLY" ] || [ "$ONLY" = "$1" ]; }

declare -A BEFORE AFTER STATUS
failed=""

printf '\n%sHermes fleet upgrade%s  %s%s%s\n' "$B" "$R" "$D" "$(date '+%Y-%m-%d %H:%M %Z')" "$R"
rule
printf '%s  %-8s %-20s %-12s %s%s\n' "$B" "TARGET" "HOST" "INSTALL" "VERSION" "$R"
for t in $TARGETS; do
    selected "$t" || continue
    BEFORE[$t]=$(version_of "$t")
    printf '  %-8s %-20s %-12s %s\n' \
        "$t" "${HOSTNAME_OF[$t]}" "${METHOD_OF[$t]}" "$(short "${BEFORE[$t]}")"
done
rule

if [ -n "$DRY_RUN" ]; then
    printf '\n%sDRY RUN%s — nothing upgraded.\n' "$YELLOW" "$R"
    exit 0
fi

for t in $TARGETS; do
    selected "$t" || continue
    printf '\n'
    rule
    printf '%s ▶ %s%s  %s— %s%s\n' "$B" "${HOSTNAME_OF[$t]}" "$R" "$D" "target: $t" "$R"
    rule
    if [ "${BEFORE[$t]}" = "unreachable" ]; then
        printf '  %sSKIPPED%s — host unreachable\n' "$RED" "$R"
        STATUS[$t]="UNREACHABLE"; AFTER[$t]="unreachable"; failed="$failed $t"
        continue
    fi
    printf '  %sbefore:%s %s\n\n' "$D" "$R" "$(short "${BEFORE[$t]}")"
    if upgrade "$t"; then
        AFTER[$t]=$(version_of "$t")
        if [ "${AFTER[$t]}" = "${BEFORE[$t]}" ]; then STATUS[$t]="CURRENT"; else STATUS[$t]="UPDATED"; fi
    else
        printf '\n  %sFAILED%s — %s exited non-zero\n' "$RED" "$R" "${HOSTNAME_OF[$t]}"
        AFTER[$t]=$(version_of "$t"); STATUS[$t]="FAILED"; failed="$failed $t"
    fi
    printf '\n  %safter:%s  %s\n' "$D" "$R" "$(short "${AFTER[$t]}")"
done

printf '\n'
rule
printf '%s  %-20s %-11s %s%s\n' "$B" "HOST" "RESULT" "VERSION" "$R"
for t in $TARGETS; do
    selected "$t" || continue
    case "${STATUS[$t]}" in
        UPDATED) color="$GREEN" ;;
        CURRENT) color="$D" ;;
        *)       color="$RED" ;;
    esac
    if [ "${STATUS[$t]}" = "UPDATED" ]; then
        detail="$(short "${BEFORE[$t]}")  →  $(short "${AFTER[$t]}")"
    else
        detail="$(short "${AFTER[$t]}")"
    fi
    printf '  %-20s %s%-11s%s %s\n' "${HOSTNAME_OF[$t]}" "$color" "${STATUS[$t]}" "$R" "$detail"
done
rule

if [ -n "$failed" ]; then
    printf '\n%sfailed/skipped:%s%s\n' "$RED" "$R" "$failed"
    exit 1
fi
