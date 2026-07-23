#!/usr/bin/env bash
# Non-interactive backend deploy — no more `sam deploy --guided` prompts.
# One-time setup: cp .deploy-secrets.env.example .deploy-secrets.env, fill in
# real values (that file is gitignored, never committed).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

if [ ! -f .deploy-secrets.env ]; then
  echo "Missing .deploy-secrets.env — copy .deploy-secrets.env.example and fill in real values." >&2
  exit 1
fi
# shellcheck disable=SC1091
source .deploy-secrets.env

"/c/Program Files/Amazon/AWSSAMCLI/bin/sam.cmd" build

"/c/Program Files/Amazon/AWSSAMCLI/bin/sam.cmd" deploy \
  --no-confirm-changeset \
  --parameter-overrides \
    DatabaseUrl="$DATABASE_URL" \
    OpenAiApiKey="$OPENAI_API_KEY" \
    JwtSecret="$JWT_SECRET" \
    Environment="production" \
    CorsOrigins="https://d2pxpnskssh5n0.cloudfront.net" \
    S3Bucket="graphrag-media-prod-jsy97-248719798440-ap-northeast-2-an" \
    MediaBaseUrl="https://d2ocj6tslcohiq.cloudfront.net" \
    DbRequireSsl="true" \
    DbDisablePreparedCache="true" \
    DbLambdaPooling="true" \
    RunDbMigrations="false"
