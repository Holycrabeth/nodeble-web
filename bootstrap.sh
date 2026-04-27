#!/usr/bin/env bash
# nodeble bootstrap script — Phase B placeholder
# https://nodeble.app/bootstrap.sh
#
# Real implementation ships ~Week 5-7 of GUI v1 backend timeline.
# Today this script is a friendly stub that just identifies itself.
#
# Production usage (NOT YET ACTIVE):
#   curl -sSL https://nodeble.app/bootstrap.sh | bash -s -- \
#     --strategy wheel \
#     --config /tmp/wheel-config.json \
#     --tiger-properties /tmp/tiger.properties
#
# See ~/projects/cto/reviews/2026-04-26-phase-4.1-backend-contract-freeze.md
# for endpoint contract this script will eventually integrate with.

set -euo pipefail

cat <<'EOF'
═══════════════════════════════════════════════════════════════════
  NODEBLE bootstrap.sh — Phase B placeholder
═══════════════════════════════════════════════════════════════════

The real install script ships in Phase B (~Week 5-7 of GUI v1
backend timeline). For now this is a stub that confirms the
domain + Cloudflare Pages + CDN are working.

If you're seeing this output, congratulations — nodeble.app is
reachable, HTTPS is live, and bootstrap delivery works.

For the current install path (manual, dev-flow), see:
  https://github.com/Holycrabeth/nodeble-wheel/blob/main/deploy/deploy.sh

For the upcoming GUI install wizard:
  - Mac app + bootstrap.sh integration ETA Week 7
  - Customer flow: Mac app → SSH to VPS → curl bootstrap.sh | bash
  - Backend Director (Tower) coordinates 4 module deploy.sh refactor

═══════════════════════════════════════════════════════════════════
EOF

# Phase B real impl will go here. For now exit 0 (success placeholder).
exit 0
