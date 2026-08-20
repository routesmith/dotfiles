#!/usr/bin/env bash
# Drive a Hermes version upgrade across the three active installs and report the
# before/after per host so silent drift can't hide again — the 2026-07-22
# original failure was Docker + macOS sitting two weeks behind while every
# local run reported success without ever naming a host or a version. Docker
# was retired from the fleet on 2026-08-11; the remaining targets stay explicit.
#
# Scope is versions only. Model/routing config is the other tool:
# `hermes-fleet-config --report|--apply` (same targets, different job).
set -uo pipefail

FULL_UPDATE="$HOME/.config/tools-local/hermes_update_full.sh"
TARGETS_FILE="$HOME/.config/tools-local/hermes-fleet-targets.local.json"
PWSH="/mnt/c/Program Files/PowerShell/7/pwsh.exe"
DASHBOARD_SERVICE="hermes-dashboard.service"

TARGETS="wsl windows macos"
usage() { echo "usage: $(basename "$0") [-n|--dry-run] [--target wsl|windows|macos]" >&2; exit 2; }

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

# Short names for display: strip the user@ and the .internal suffix.
macos_short="${MACOS_HOST#*@}"; macos_short="${macos_short%%.*}"

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
)
declare -A METHOD_OF=([wsl]="git" [windows]="git" [macos]="git")

if [ -t 1 ]; then
    B=$(tput bold); D=$(tput dim); R=$(tput sgr0)
    GREEN=$(tput setaf 2); YELLOW=$(tput setaf 3); RED=$(tput setaf 1)
else
    B=""; D=""; R=""; GREEN=""; YELLOW=""; RED=""
fi

rule() { printf '%s%s%s\n' "$D" "$(printf '─%.0s' {1..78})" "$R"; }

# Hermes removed the `version` subcommand on 2026-08-20, so a staggered fleet
# can temporarily contain both interfaces. Older `--version` output lacks the
# git provenance carried by `hermes version`; prefer the current form, but ask
# the legacy form for the richer line when the current line has no provenance.
invoke_version() {
    local target=$1 form=$2
    case "$target:$form" in
        wsl:current)     hermes --version ;;
        wsl:legacy)      hermes version ;;
        windows:current) "$PWSH" -NoProfile -NonInteractive -Command \
                             '& "$env:LOCALAPPDATA\hermes\hermes-agent\venv\Scripts\hermes.exe" --version' ;;
        windows:legacy)  "$PWSH" -NoProfile -NonInteractive -Command \
                             '& "$env:LOCALAPPDATA\hermes\hermes-agent\venv\Scripts\hermes.exe" version' ;;
        macos:current)   ssh -o ConnectTimeout=15 "$MACOS_HOST" 'zsh -lic "hermes --version"' ;;
        macos:legacy)    ssh -o ConnectTimeout=15 "$MACOS_HOST" 'zsh -lic "hermes version"' ;;
    esac
}

version_line() { tr -d '\r' | grep -m1 '^Hermes Agent'; }

version_of() {
    local target=$1 current current_rc legacy legacy_rc
    if [ "$target" = "windows" ] && [ ! -x "$PWSH" ]; then
        printf 'unreachable'
        return 10
    fi

    current=$(invoke_version "$target" current 2>/dev/null); current_rc=$?
    current=$(printf '%s\n' "$current" | version_line || true)
    if [ "$current_rc" -eq 0 ] && [[ "$current" == *" · upstream "* ]]; then
        printf '%s' "$current"
        return 0
    fi

    legacy=$(invoke_version "$target" legacy 2>/dev/null); legacy_rc=$?
    legacy=$(printf '%s\n' "$legacy" | version_line || true)
    if [ "$legacy_rc" -eq 0 ] && [ -n "$legacy" ]; then
        printf '%s' "$legacy"
        return 0
    fi
    if [ "$current_rc" -eq 0 ] && [ -n "$current" ]; then
        printf '%s' "$current"
        return 0
    fi

    if [ "$target" = "macos" ] && [ "$current_rc" -eq 255 ] && [ "$legacy_rc" -eq 255 ]; then
        printf 'unreachable'
        return 10
    fi
    if [ "$target" = "windows" ] \
        && [[ "$current_rc" -eq 126 || "$current_rc" -eq 127 ]] \
        && [[ "$legacy_rc" -eq 126 || "$legacy_rc" -eq 127 ]]; then
        printf 'unreachable'
        return 10
    fi
    printf 'probe failed'
    return 11
}

gateway_status_of() {
    case "$1" in
        wsl)     hermes gateway status ;;
        windows) "$PWSH" -NoProfile -NonInteractive -Command \
                     '& "$env:LOCALAPPDATA\hermes\hermes-agent\venv\Scripts\hermes.exe" gateway status' ;;
        macos)   ssh -o ConnectTimeout=15 "$MACOS_HOST" 'zsh -lic "hermes gateway status"' ;;
    esac
}

# A non-zero update can still leave a healthy target after the host wrapper's
# EXIT-trap reconciliation. Prove that state instead of inferring it from logs.
target_healthy() {
    local target=$1 gateway gateway_rc dashboard
    gateway=$(gateway_status_of "$target" 2>&1); gateway_rc=$?
    printf '%s\n' "$gateway"
    [ "$gateway_rc" -eq 0 ] || return 1
    printf '%s\n' "$gateway" | grep -Eiq \
        '^✓ (.*gateway.*running|Gateway is supervised by launchd|Detached fallback process is running)' \
        || return 1

    if [ "$target" = "wsl" ]; then
        dashboard=$(systemctl --user is-active "$DASHBOARD_SERVICE" 2>/dev/null || true)
        printf 'Dashboard: %s\n' "${dashboard:-unknown}"
        [ "$dashboard" = "active" ] || return 1
    fi
}

# "Hermes Agent v0.19.0 (2026.7.20) · upstream deadb43c · local 5a47f952 (+1…)"
#   -> "v0.19.0 (2026.7.20)  origin/main:deadb43c  local:5a47f952"
# Hermes's "upstream" field is the locally cached origin/main ref, not the
# installed HEAD. Keep any explicit local sha, which is the checked-out commit.
short() {
    [[ "$1" = "unreachable" || "$1" = "probe failed" ]] && { printf '%s' "$1"; return; }
    printf '%s' "$1" | sed -E '
        s/^Hermes Agent //
        s/ · upstream /  origin\/main:/
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
    esac
}

selected() { [ -z "$ONLY" ] || [ "$ONLY" = "$1" ]; }

declare -A BEFORE AFTER STATUS BEFORE_PROBE AFTER_PROBE UPGRADE_RC HEALTH_RC
failed=""
recovered=""

printf '\n%sHermes fleet upgrade%s  %s%s%s\n' "$B" "$R" "$D" "$(date '+%Y-%m-%d %H:%M %Z')" "$R"
rule
printf '%s  %-8s %-20s %-12s %s%s\n' "$B" "TARGET" "HOST" "INSTALL" "VERSION" "$R"
for t in $TARGETS; do
    selected "$t" || continue
    BEFORE[$t]=$(version_of "$t"); BEFORE_PROBE[$t]=$?
    printf '  %-8s %-20s %-12s %s\n' \
        "$t" "${HOSTNAME_OF[$t]}" "${METHOD_OF[$t]}" "$(short "${BEFORE[$t]}")"
done
rule

if [ -n "$DRY_RUN" ]; then
    printf '\n%sDRY RUN%s — nothing upgraded.\n' "$YELLOW" "$R"
    exit 0
fi

# The legs are independent, so they run in parallel — wall clock is the
# slowest leg, not the sum. Verified before parallelizing: no remaining leg
# reads what another writes. Output is buffered per
# target and replayed sequentially so each section stays one host's story.
LOGDIR=$(mktemp -d); trap 'rm -rf "$LOGDIR"' EXIT
for t in $TARGETS; do
    selected "$t" || continue
    [ "${BEFORE_PROBE[$t]}" -ne 0 ] && continue
    printf '  %sstarted%s %s\n' "$D" "$R" "${HOSTNAME_OF[$t]}"
    (
        upgrade "$t" >"$LOGDIR/$t.log" 2>&1 </dev/null
        upgrade_rc=$?
        echo "$upgrade_rc" >"$LOGDIR/$t.rc"
        version_of "$t" >"$LOGDIR/$t.after"
        echo $? >"$LOGDIR/$t.after.rc"
        if [ "$upgrade_rc" -ne 0 ]; then
            target_healthy "$t" >"$LOGDIR/$t.health" 2>&1
            echo $? >"$LOGDIR/$t.health.rc"
        fi
    ) &
done
wait

for t in $TARGETS; do
    selected "$t" || continue
    printf '\n'
    rule
    printf '%s ▶ %s%s  %s— %s%s\n' "$B" "${HOSTNAME_OF[$t]}" "$R" "$D" "target: $t" "$R"
    rule
    if [ "${BEFORE_PROBE[$t]}" -eq 10 ]; then
        printf '  %sSKIPPED%s — host unreachable\n' "$RED" "$R"
        STATUS[$t]="UNREACHABLE"; AFTER[$t]="unreachable"; failed="$failed $t"
        continue
    fi
    if [ "${BEFORE_PROBE[$t]}" -ne 0 ]; then
        printf '  %sSKIPPED%s — host reachable but Hermes version probe failed\n' "$RED" "$R"
        STATUS[$t]="PROBE FAILED"; AFTER[$t]="probe failed"; failed="$failed $t"
        continue
    fi
    printf '  %sbefore:%s %s\n\n' "$D" "$R" "$(short "${BEFORE[$t]}")"
    cat "$LOGDIR/$t.log"
    AFTER[$t]=$(cat "$LOGDIR/$t.after" 2>/dev/null || printf 'probe failed')
    AFTER_PROBE[$t]=$(cat "$LOGDIR/$t.after.rc" 2>/dev/null || echo 11)
    UPGRADE_RC[$t]=$(cat "$LOGDIR/$t.rc" 2>/dev/null || echo 1)
    if [ "${UPGRADE_RC[$t]}" = "0" ] && [ "${AFTER_PROBE[$t]}" = "0" ]; then
        if [ "${AFTER[$t]}" = "${BEFORE[$t]}" ]; then STATUS[$t]="CURRENT"; else STATUS[$t]="UPDATED"; fi
    elif [ "${UPGRADE_RC[$t]}" != "0" ]; then
        HEALTH_RC[$t]=$(cat "$LOGDIR/$t.health.rc" 2>/dev/null || echo 1)
        if [ "${AFTER_PROBE[$t]}" = "0" ] && [ "${HEALTH_RC[$t]}" = "0" ]; then
            printf '\n  %sRECOVERED%s — update command exited %s; final version and runtime checks succeeded\n' \
                "$YELLOW" "$R" "${UPGRADE_RC[$t]}"
            STATUS[$t]="RECOVERED"; recovered="$recovered $t(rc=${UPGRADE_RC[$t]})"
        else
            printf '\n  %sFAILED%s — update command exited %s; final health was not established\n' \
                "$RED" "$R" "${UPGRADE_RC[$t]}"
            STATUS[$t]="FAILED"; failed="$failed $t"
        fi
    else
        printf '\n  %sFAILED%s — update exited zero but the final version probe failed\n' "$RED" "$R"
        STATUS[$t]="FAILED"; failed="$failed $t"
    fi
    printf '\n  %safter:%s  %s\n' "$D" "$R" "$(short "${AFTER[$t]}")"
done

printf '\n'
rule
printf '%s  %-20s %-12s %s%s\n' "$B" "HOST" "RESULT" "VERSION" "$R"
for t in $TARGETS; do
    selected "$t" || continue
    case "${STATUS[$t]}" in
        UPDATED) color="$GREEN" ;;
        CURRENT) color="$D" ;;
        RECOVERED) color="$YELLOW" ;;
        *)       color="$RED" ;;
    esac
    if [[ "${STATUS[$t]}" = "UPDATED" || "${STATUS[$t]}" = "RECOVERED" ]]; then
        detail="$(short "${BEFORE[$t]}")  →  $(short "${AFTER[$t]}")"
    else
        detail="$(short "${AFTER[$t]}")"
    fi
    printf '  %-20s %s%-12s%s %s\n' "${HOSTNAME_OF[$t]}" "$color" "${STATUS[$t]}" "$R" "$detail"
done
rule

# ponytail: $SECONDS is total shell runtime; date -u -d @ formats it as H:MM:SS.
# Fine under 24h — a fleet run that long has bigger problems than a clock.
printf '%sfinished%s  %s%s%s  ·  %selapsed%s %s\n' \
    "$D" "$R" "$D" "$(date '+%Y-%m-%d %H:%M:%S %Z')" "$R" "$D" "$R" "$(date -u -d @"$SECONDS" +%-H:%M:%S)"

if [ -n "$recovered" ]; then
    printf '\n%srecovered after update-command failure:%s%s\n' "$YELLOW" "$R" "$recovered"
fi
if [ -n "$failed" ]; then
    printf '\n%sfailed/skipped:%s%s\n' "$RED" "$R" "$failed"
    exit 1
fi
