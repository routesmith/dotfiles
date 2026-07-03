#!/usr/bin/env bash
set -euo pipefail

DASHBOARD_SERVICE="hermes-dashboard.service"
HERMES_DIR="$HOME/.hermes/hermes-agent"
UI_DIR="$HERMES_DIR/ui-tui"
# Local feature branch reapplied after every update (see vault:
# wiki/concepts/Hermes CLI Vi Mode.md). Empty string disables the step.
# feat/onepassword-secrets-20260612 stacks the 1Password secret source
# (upstream PR #36896) on the vi-mode commit, so one rebase carries both
# features; the pure feat/cli-vi-mode-20260610 branch is kept for the
# upstream vi-mode PR and is NOT rebased automatically.
FEATURE_BRANCH="feat/onepassword-secrets-20260612"

DRY_RUN=""
case "${1:-}" in
    -n|--dry-run) DRY_RUN=1 ;;
    "") ;;
    *) echo "usage: $(basename "$0") [-n|--dry-run]" >&2; exit 2 ;;
esac

# Reapply the feature branch and restart the gateway. Runs from a trap on
# EXIT so it happens even if a build step below fails. `hermes update` leaves
# the repo on vanilla main, which has NO op:// secret support — so a gateway
# left on main silently loses every 1Password secret (provider keys, Discord/
# Telegram bot tokens) and all platforms drop. Returning to the feature branch
# is the one step that must never be skipped, so it lives in the trap.
finalize() {
    set +e
    if [ -n "$FEATURE_BRANCH" ] && git -C "$HERMES_DIR" show-ref --verify --quiet "refs/heads/$FEATURE_BRANCH"; then
        # npm rewrites these; discard so the rebase sees a clean tree.
        git -C "$HERMES_DIR" restore package.json package-lock.json 2>/dev/null
        # cli-config.yaml.example is a comments-only template; upstream and our
        # secrets stack both append example blocks to it, so the rebase below
        # conflicts there every time upstream touches that file — and the abort
        # path then strands the branch hundreds of commits behind (this is the
        # 243-commit drift we hit 2026-06-30). Union-merge that one file so git
        # keeps both blocks automatically. Host-local + untracked so it never
        # leaks into the stack or an upstream PR; idempotent so it self-heals on
        # any host that runs this script.
        # ponytail: file-level union, not line-scoped. Worst case is a duplicate
        # commented block in a template the operator copies once via `hermes
        # doctor` — never loaded into a live gateway. Narrow it only if the
        # active YAML at the top of the file ever starts conflicting.
        attrs="$HERMES_DIR/.git/info/attributes"
        grep -qxF 'cli-config.yaml.example merge=union' "$attrs" 2>/dev/null \
            || echo 'cli-config.yaml.example merge=union' >> "$attrs"
        if [ "$(git -C "$HERMES_DIR" rev-parse --abbrev-ref HEAD)" != "$FEATURE_BRANCH" ]; then
            echo "==> Reapplying $FEATURE_BRANCH onto updated main..."
            if ! git -C "$HERMES_DIR" rebase main "$FEATURE_BRANCH"; then
                git -C "$HERMES_DIR" rebase --abort
                # ponytail: on conflict, stay on the feature branch (pre-update
                # base) rather than main. Code is one upstream rev behind until
                # you re-port, but the gateway keeps its 1Password secrets and
                # platforms — strictly better than a secret-less main.
                git -C "$HERMES_DIR" checkout "$FEATURE_BRANCH"
                echo "!!> Rebase conflicted; staying on $FEATURE_BRANCH (pre-update base)."
                echo "!!> Re-port when convenient: git -C $HERMES_DIR rebase main $FEATURE_BRANCH"
            fi
        fi
    fi
    echo "==> Restarting gateway (picks up feature branch + refreshes unit)..."
    hermes gateway restart
    sleep 5
    echo "  Platforms: $(grep 'platform(s)' ~/.hermes/logs/gateway.log | tail -1)"
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
    echo "  feature branch:     $FEATURE_BRANCH ($(git -C "$HERMES_DIR" show-ref --verify --quiet "refs/heads/$FEATURE_BRANCH" && echo present || echo MISSING))"
    echo "  behind origin/main: $behind commit(s) as of last fetch — 'hermes update' fast-forwards main, then rebases the feature branch onto it"
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

echo "==> Build steps complete; finalize trap will reapply branch + restart."
