#!/usr/bin/env bash
set -euo pipefail

: "${WEB_BUCKET:?WEB_BUCKET is required}"
: "${WEB_DISTRIBUTION_ID:?WEB_DISTRIBUTION_ID is required}"
: "${APP_VERSION:?APP_VERSION is required}"
: "${API_BASE_URL:?API_BASE_URL is required}"

build_dir="${1:-mobile/build/web}"
previous_index="$(aws s3api list-object-versions --bucket "$WEB_BUCKET" --prefix index.html --query 'Versions[?IsLatest].VersionId | [0]' --output text)"
previous_version="$(aws s3api list-object-versions --bucket "$WEB_BUCKET" --prefix version.json --query 'Versions[?IsLatest].VersionId | [0]' --output text)"

# Flutter emits fixed names for its application loader and main bundle.  They
# must never be immutable: a browser that has an older main.dart.js cached
# would otherwise keep calling its previous API URL even after CloudFront was
# invalidated.  Version the two references as a release-level cache buster and
# upload every fixed entrypoint with revalidation headers.
sed -i "s#flutter_bootstrap\.js#flutter_bootstrap.js?v=${APP_VERSION}#g" "$build_dir/index.html"
sed -i "s#main\.dart\.js\"#main.dart.js?v=${APP_VERSION}\"#g" "$build_dir/flutter_bootstrap.js"
uncached_files=(
  index.html
  version.json
  flutter_bootstrap.js
  flutter_service_worker.js
  flutter.js
  flutter.js.map
  main.dart.js
  manifest.json
)

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
sync_args=()
for file in "${uncached_files[@]}"; do
  sync_args+=(--exclude "$file")
done
aws s3 sync "$build_dir" "s3://$WEB_BUCKET" --delete "${sync_args[@]}" --cache-control 'public,max-age=31536000,immutable'
for file in "${uncached_files[@]}"; do
  if [[ -f "$build_dir/$file" ]]; then
    aws s3 cp "$build_dir/$file" "s3://$WEB_BUCKET/$file" --cache-control 'no-cache,no-store,must-revalidate'
  fi
done
invalidation_id="$(aws cloudfront create-invalidation --distribution-id "$WEB_DISTRIBUTION_ID" --paths '/*' --query 'Invalidation.Id' --output text)"
aws cloudfront wait invalidation-completed --distribution-id "$WEB_DISTRIBUTION_ID" --id "$invalidation_id"
printf 'invalidation_id=%s\n' "$invalidation_id" >> "$GITHUB_OUTPUT"
trap - EXIT
