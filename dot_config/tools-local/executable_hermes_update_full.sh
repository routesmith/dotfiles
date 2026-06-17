#!/usr/bin/env bash
set -euo pipefail

DASHBOARD_SERVICE="hermes-dashboard.service"
UI_DIR="$HOME/.hermes/hermes-agent/ui-tui"

echo "==> Running: hermes update"
START=$(date +%s)
hermes update
END=$(date +%s)
ELAPSED=$((END - START))
echo "==> hermes update completed in ${ELAPSED}s"

echo "==> Installing dependencies..."
cd "$HOME/.hermes/hermes-agent"
npm install

echo "==> Rebuilding dashboard UI..."
cd "$UI_DIR"
npm run build

echo "==> Restarting dashboard service..."
systemctl --user restart "$DASHBOARD_SERVICE"

echo "==> Done. Dashboard status:"
systemctl --user status "$DASHBOARD_SERVICE" --no-pager -l | head -6
