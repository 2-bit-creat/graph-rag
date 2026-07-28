#!/usr/bin/env bash
set -euo pipefail

: "${STACK_NAME:=graph-rag-backend}"
: "${AWS_REGION:=ap-northeast-2}"
target_dir="${1:-deploy-diagnostics}"
mkdir -p "$target_dir"
aws cloudformation describe-stack-events --stack-name "$STACK_NAME" --region "$AWS_REGION" > "$target_dir/stack-events.json" || true
function_name="$(aws cloudformation describe-stack-resource --stack-name "$STACK_NAME" --logical-resource-id GraphRagFunction --region "$AWS_REGION" --query 'StackResourceDetail.PhysicalResourceId' --output text 2>/dev/null || true)"
if [[ -n "$function_name" && "$function_name" != "None" ]]; then
  aws logs tail "/aws/lambda/$function_name" --since 20m --region "$AWS_REGION" --format short > "$target_dir/lambda.log" 2>&1 || true
fi
if [[ -f "$target_dir/lambda.log" ]]; then
  sed -E -i.bak -e 's/(sk-[A-Za-z0-9_-]{8,})/[REDACTED]/g' -e 's/(postgres(ql)?:\/\/)[^ @]+/\1[REDACTED]/g' "$target_dir/lambda.log" || true
  rm -f "$target_dir/lambda.log.bak"
fi
