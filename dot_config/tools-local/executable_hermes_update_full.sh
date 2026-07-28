#!/usr/bin/env bash
set -euo pipefail

DASHBOARD_SERVICE="hermes-dashboard.service"
HERMES_DIR="$HOME/.hermes/hermes-agent"
UI_DIR="$HERMES_DIR/ui-tui"
# 2026-07-28: the fleet is zero-carry. 1Password merged upstream 2026-07-06, and
# the last carried commit (CLI vi-mode) was dropped today — its 3-line entry in
# hermes_cli/commands.py collided with every upstream slash-command addition, and
# the abort-fallback silently pinned the branch (749 commits behind by the time it
# surfaced). Every install now tracks origin/main directly, so this script no
# longer reapplies anything: it updates, builds, and restarts.

DRY_RUN=""
case "${1:-}" in
    -n|--dry-run) DRY_RUN=1 ;;
    "") ;;
    *) echo "usage: $(basename "$0") [-n|--dry-run]" >&2; exit 2 ;;
esac

# Restart the gateway. Runs from a trap on EXIT so it happens even if a build
# step below fails — `hermes update` does its own mid-script restart, but that
# one never refreshes the systemd unit.
finalize() {
    set +e
    echo "==> Restarting gateway (refreshes unit)..."
    if command -v systemctl >/dev/null 2>&1; then
        hermes gateway restart
    else
        # ponytail: without systemd, `hermes gateway restart` IS the gateway —
        # it runs foreground forever, which hangs this script (and any SSH
        # session driving it). Detach so the script can exit and the gateway
        # survives the session.
        nohup hermes gateway restart >> "$HOME/.hermes/logs/gateway-restart.log" 2>&1 &
        disown
    fi
    sleep 5
    echo "  Platforms: $(grep 'platform(s)' ~/.hermes/logs/gateway.log | tail -1)"
    echo "==> After:  $(uname -n) is now $(hermes version 2>/dev/null | grep -m1 '^Hermes Agent' || echo unknown)"
    # ponytail: the dashboard runs under user systemd; hosts without systemctl
    # (e.g. macOS) skip it. Guard rather than fork a second copy of this script.
    if command -v systemctl >/dev/null 2>&1; then
        echo "==> Restarting dashboard service..."
        systemctl --user restart "$DASHBOARD_SERVICE"
        systemctl --user status "$DASHBOARD_SERVICE" --no-pager -l | head -6
    fi
}

# Read-only preview of what a real run would do; --dry-run stops here so the
# updater can be inspected on a host before it mutates anything.
plan() {
    local cur behind
    cur=$(git -C "$HERMES_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')
    behind=$(git -C "$HERMES_DIR" rev-list --count HEAD..origin/main 2>/dev/null || echo '?')
    echo "DRY RUN — no changes will be made."
    echo "  repo:               $HERMES_DIR"
    echo "  current branch:     $cur"
    echo "  behind origin/main: $behind commit(s) as of last fetch — 'hermes update' fast-forwards main"
    echo "  guards:"
    echo "    npm install:        $(command -v npm >/dev/null 2>&1 && echo RUN || echo SKIP)"
    echo "    ui-tui build:       $([ -d "$UI_DIR" ] && echo RUN || echo SKIP)"
    echo "    dashboard restart:  $(command -v systemctl >/dev/null 2>&1 && echo RUN || echo SKIP)"
}

if [ -n "$DRY_RUN" ]; then plan; exit 0; fi
trap finalize EXIT

# npm install rewrites package-lock.json (version-dependent churn, not real
# work). Discard it up front so hermes update doesn't stash/restore.
git -C "$HERMES_DIR" restore package-lock.json

# Name the machine and the starting version. This script runs identically on
# every host (locally and over ssh from hermes_update_fleet.sh), so output with
# no host in it is unreadable the moment more than one install exists.
echo "==> Host: $(uname -n) ($(uname -s))  dir: $HERMES_DIR"
echo "==> Before: $(hermes version 2>/dev/null | grep -m1 '^Hermes Agent' || echo unknown)"

echo "==> Running: hermes update"
START=$(date +%s)
hermes update
END=$(date +%s)
ELAPSED=$((END - START))
echo "==> hermes update completed in ${ELAPSED}s"

if command -v npm >/dev/null 2>&1; then
    echo "==> Installing dependencies..."
    cd "$HERMES_DIR"
    npm install
fi

# ponytail: the ui-tui dashboard only exists where it has been built; a
# plain-gateway host has no dashboard dir. Skip the build when it isn't present.
if [ -d "$UI_DIR" ]; then
    echo "==> Rebuilding dashboard UI..."
    cd "$UI_DIR"
    npm run build
fi

echo "==> Build steps complete; finalize trap will restart the gateway."
