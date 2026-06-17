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

# npm install rewrites package-lock.json (version-dependent churn, not real
# work). Discard it up front so hermes update doesn't stash/restore.
git -C "$HERMES_DIR" restore package-lock.json

echo "==> Running: hermes update"
START=$(date +%s)
hermes update
END=$(date +%s)
ELAPSED=$((END - START))
echo "==> hermes update completed in ${ELAPSED}s"

echo "==> Installing dependencies..."
cd "$HERMES_DIR"
npm install

echo "==> Rebuilding dashboard UI..."
cd "$UI_DIR"
npm run build

if [ -n "$FEATURE_BRANCH" ] && git -C "$HERMES_DIR" show-ref --verify --quiet "refs/heads/$FEATURE_BRANCH"; then
    echo "==> Reapplying $FEATURE_BRANCH onto updated main..."
    git -C "$HERMES_DIR" restore package-lock.json
    if git -C "$HERMES_DIR" rebase main "$FEATURE_BRANCH"; then
        echo "==> $FEATURE_BRANCH rebased and checked out"
    else
        git -C "$HERMES_DIR" rebase --abort || true
        git -C "$HERMES_DIR" checkout main
        echo "!!> Rebase hit conflicts (upstream changed the same code)."
        echo "!!> Left on vanilla main so Hermes keeps working. Re-port with:"
        echo "!!>   git -C $HERMES_DIR rebase main $FEATURE_BRANCH"
    fi
fi

echo "==> Restarting gateway (picks up feature branch + refreshes unit)..."
hermes gateway restart
sleep 5
echo "  Platforms:"
grep "platform(s)" ~/.hermes/logs/gateway.log | tail -1

echo "==> Restarting dashboard service..."
systemctl --user restart "$DASHBOARD_SERVICE"

echo "==> Done. Dashboard status:"
systemctl --user status "$DASHBOARD_SERVICE" --no-pager -l | head -6
