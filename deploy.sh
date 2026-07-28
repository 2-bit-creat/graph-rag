#!/usr/bin/env bash
# Production deploys run through GitHub Actions using OIDC and Secrets Manager.
# This compatibility entrypoint deliberately never reads local secret files.
set -euo pipefail

cat <<'EOF'
Production deploys are automated:
  git push origin main

For a retry or a frontend/backend-only release, use Actions →
"CI and production deployment" → Run workflow. The workflow does not read
.env, .env.*, or .deploy-secrets.env.
EOF
