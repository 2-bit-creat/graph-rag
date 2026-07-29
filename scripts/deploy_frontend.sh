#!/usr/bin/env bash
set -euo pipefail

: "${WEB_BUCKET:?WEB_BUCKET is required}"
: "${WEB_DISTRIBUTION_ID:?WEB_DISTRIBUTION_ID is required}"
: "${APP_VERSION:?APP_VERSION is required}"
: "${API_BASE_URL:?API_BASE_URL is required}"

build_dir="${1:-mobile/build/web}"
previous_index="$(aws s3api list-object-versions --bucket "$WEB_BUCKET" --prefix index.html --query 'Versions[?IsLatest].VersionId | [0]' --output text)"
previous_version="$(aws s3api list-object-versions --bucket "$WEB_BUCKET" --prefix version.json --query 'Versions[?IsLatest].VersionId | [0]' --output text)"

rollback() {
  status=$?
  if [[ $status -ne 0 && "$previous_index" != "None" && "$previous_index" != "" ]]; then
    aws s3api copy-object --bucket "$WEB_BUCKET" --key index.html --copy-source "$WEB_BUCKET/index.html?versionId=$previous_index" >/dev/null
    if [[ "$previous_version" != "None" && "$previous_version" != "" ]]; then
      aws s3api copy-object --bucket "$WEB_BUCKET" --key version.json --copy-source "$WEB_BUCKET/version.json?versionId=$previous_version" >/dev/null
    fi
    aws cloudfront create-invalidation --distribution-id "$WEB_DISTRIBUTION_ID" --paths '/*' >/dev/null
  fi
  exit "$status"
}
trap rollback EXIT

printf '{"git_sha":"%s","built_at":"%s","api_base_url":"%s"}\n' \
  "$APP_VERSION" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$API_BASE_URL" > "$build_dir/version.json"
aws s3 sync "$build_dir" "s3://$WEB_BUCKET" --delete --exclude index.html --exclude version.json --cache-control 'public,max-age=31536000,immutable'
aws s3 cp "$build_dir/index.html" "s3://$WEB_BUCKET/index.html" --cache-control 'no-cache,no-store,must-revalidate'
aws s3 cp "$build_dir/version.json" "s3://$WEB_BUCKET/version.json" --cache-control 'no-cache,no-store,must-revalidate'
invalidation_id="$(aws cloudfront create-invalidation --distribution-id "$WEB_DISTRIBUTION_ID" --paths '/*' --query 'Invalidation.Id' --output text)"
aws cloudfront wait invalidation-completed --distribution-id "$WEB_DISTRIBUTION_ID" --id "$invalidation_id"
printf 'invalidation_id=%s\n' "$invalidation_id" >> "$GITHUB_OUTPUT"
trap - EXIT
