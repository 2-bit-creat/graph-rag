# Deployment — architecture, workflow, and what broke

This documents the AWS deployment set up for this project (Lambda + Neon + S3/CloudFront)
and, more importantly, the **development workflow** that came out of debugging it —
several real production-only bugs are cheap to explain in hindsight but expensive to
hit blind. Read this before touching anything deploy-related.

## Architecture

```
Flutter Web (S3 + CloudFront, OAC)  ──┐
                                       ├─→ browser calls the Lambda Function URL directly
Lambda (container image, x86_64)  ←───┘        (not routed through CloudFront — see "Why
  │                                              not API Gateway / why direct" below)
  ├─→ Neon Postgres (pgvector, pooled endpoint, ap-southeast-1)
  └─→ S3 media bucket (audio uploads + quiz TTS) ──→ CloudFront (OAC) ──→ playable URLs
```

### Live resources (region `ap-northeast-2`, account `248719798440`)

| Resource | Value |
|---|---|
| CloudFormation stack | `graph-rag-backend` |
| Lambda Function URL (= `API_BASE_URL`) | `https://u7dslgxujnagqzkhesyvj3sop40dfejb.lambda-url.ap-northeast-2.on.aws` |
| Web bucket | `graphrag-web-prod-jsy97-248719798440-ap-northeast-2-an` |
| Web CloudFront (Flutter app) | `https://d2pxpnskssh5n0.cloudfront.net` (dist. `E34UPVZH9U8KG4`) |
| Media bucket | `graphrag-media-prod-jsy97-248719798440-ap-northeast-2-an` |
| Media CloudFront (`MEDIA_BASE_URL`) | `https://d2ocj6tslcohiq.cloudfront.net` (dist. `E9XVCK79B7R9G`) |
| DB | Neon, pooled endpoint, `ap-southeast-1` |

The Lambda's actual physical function name (`graph-rag-backend-GraphRagFunction-xxxxx`) can drift
if the function resource is ever replaced — look it up rather than trust a hardcoded copy:

```bash
aws cloudformation describe-stack-resource --stack-name graph-rag-backend \
  --logical-resource-id GraphRagFunction --region ap-northeast-2 --profile my-ai-app \
  --query "StackResourceDetail.PhysicalResourceId" --output text
```

## The three-stage workflow

**Don't go straight from "code change" to "deploy."** Several bugs in this project were
*only* reproducible against the real Lambda + real remote DB — local docker-compose could
not have caught them because it has no read-only filesystem, no cross-region latency, and
no Function URL. Concretely, hit today:

- `debug_runs_dir` mkdir crashed on Lambda's read-only `/var/task` — invisible locally.
- `init_db()`'s ~90 migration statements took 60-90s against remote Neon (Seoul↔Singapore
  round trips) — instant against local Postgres on the same machine.
- Lambda Function URL's native CORS + FastAPI's `CORSMiddleware` both added
  `Access-Control-Allow-Origin`, producing a duplicate-header response the browser
  rejects — no way to see this without an actual Function URL in front of the app.
- The Lambda execution role had **zero** S3 permissions — a local docker-compose run
  never touches IAM at all.

So the workflow is:

### 1. Local docker-compose — fast, free, logic-only
```bash
docker compose up -d postgres redis minio
cd backend && .venv/Scripts/python.exe -m pytest -q
```
Catches: business logic, query correctness, schema issues, most regressions. Zero AWS cost,
zero network latency to worry about. This is where almost all iteration should happen.

### 2. `sam local invoke` against the *real* Neon DB — catches Lambda-only bugs, no AWS cost
Before deploying, run the actual Lambda container image locally, pointed at the real
database, using the real Environment variables (pull them once, keep them handy — see
"Secrets" below):
```bash
sam build
sam local invoke GraphRagFunction --event <event.json> --env-vars <env_overrides.json>
```
This exercises the exact code path (`lambda_handler.py` → Mangum → FastAPI lifespan →
`init_db()` → your route) against production data, without pushing anything to ECR or
touching CloudFormation. It's the single most valuable step introduced this session — it
would have caught all four bugs listed above before a real deploy.

Minimal `--event` for a GET request (adjust `rawPath`):
```json
{
  "version": "2.0", "routeKey": "$default", "rawPath": "/health", "rawQueryString": "",
  "headers": {"host": "localhost"},
  "requestContext": {"http": {"method": "GET", "path": "/health", "protocol": "HTTP/1.1", "sourceIp": "127.0.0.1"}, "domainName": "localhost", "stage": "$default"},
  "isBase64Encoded": false
}
```
`--env-vars` needs the real deployed values wrapped as `{"GraphRagFunction": {...}}` — pull
them fresh before relying on them (they can go stale across sessions):
```bash
aws lambda get-function-configuration --function-name <physical-name> \
  --region ap-northeast-2 --profile my-ai-app --query "Environment.Variables" --output json
```

### 3. `bash deploy.sh` — only once step 2 looks right
```bash
bash deploy.sh
```
Non-interactive (see "Secrets" below). Only pushes the image layers that actually
changed — if `requirements.txt` is untouched, the heavy dependency layer is reused and
only the thin app-code layer re-uploads (seconds, not minutes).

**Don't skip step 2 to save time.** Every skip this session turned into a slower
deploy → discover it's broken → fix → redeploy loop, which burns far more time and
bandwidth than one `sam local invoke`.

## Secrets — no more `sam deploy --guided` every time

`sam deploy --guided` deliberately never saves `NoEcho` parameters (`DatabaseUrl`,
`OpenAiApiKey`, `JwtSecret`) into `samconfig.toml` — that's a security feature, not a bug.
Instead:

- **`.deploy-secrets.env`** (gitignored, never committed) holds the three real secret
  values as `KEY=value` lines.
- **`.deploy-secrets.env.example`** (committed) is the template — copy it once:
  ```bash
  cp .deploy-secrets.env.example .deploy-secrets.env
  # then fill in real values
  ```
- **`deploy.sh`** sources `.deploy-secrets.env` and calls `sam build` + `sam deploy
  --no-confirm-changeset --parameter-overrides ...` with every parameter explicit —
  fully non-interactive, no prompts, safe to run repeatedly.

If you ever need to change a non-secret parameter (CORS origin, media bucket, etc.),
edit the literal values inside `deploy.sh` directly.

## Architecture decisions (and why — don't undo these blind)

- **x86_64, not arm64/Graviton.** Emulated arm64 Docker builds hit a containerd
  content-store export bug on this dev machine (`content digest ... not found`),
  reproduced consistently across a Docker Desktop restart and a fresh base-image pull.
  A side-by-side native (x86_64) build succeeded cleanly every time. Costs ~20% more
  per ms than Graviton would; revisit if building on real arm64 hardware (e.g. CodeBuild)
  becomes available.
- **No `ReservedConcurrentExecutions`.** This AWS account's whole-region Lambda
  concurrency limit is 10 (fresh-account default), and AWS requires ≥10 *unreserved*
  remain after any reservation — so no positive reservation is possible until a quota
  increase is requested. The account-wide limit already acts as the cost ceiling.
- **`RUN_DB_MIGRATIONS=false` by default.** `init_db()`'s ~90 idempotent
  ALTER/CREATE-INDEX statements are cheap against co-located docker-compose Postgres,
  but each is a real network round trip against remote Neon (measured ~60-70s total,
  cross-region). Fine once; not worth eating the cold-start timeout budget on every
  container. Flip to `"true"` for exactly one deploy after a schema change (new
  migration added to `_MIGRATIONS` in `backend/app/db.py`), then flip back.
- **IPv4 forced for DB connections** (`socket.getaddrinfo` patched in `db.py`). Neon
  hostnames publish both A and AAAA records; a Lambda outside a VPC has no IPv6 egress,
  so an AAAA-first connection attempt can hang. Kept as a safety net even though the
  actual multi-minute hangs turned out to be caused by the migration round-trip issue
  above, not IPv6 — harmless locally (docker-compose Postgres is IPv4/localhost anyway).
- **CORS has exactly one owner: FastAPI's `CORSMiddleware`.** The Lambda
  `FunctionUrlConfig` has no `Cors` block. Configuring CORS in both places makes the
  Function URL and the app each add their own `Access-Control-Allow-Origin`, and the
  browser rejects a response carrying the same header twice.
- **Neon connection quirks**, all gated behind settings that default off (no effect on
  local docker-compose): `DB_REQUIRE_SSL` (Neon requires TLS; the SQLAlchemy URL's
  `?sslmode=...` query param isn't understood by asyncpg — set `connect_args={"ssl":
  True}` instead and strip the query string from `DATABASE_URL` entirely),
  `DB_DISABLE_PREPARED_CACHE` (Neon's pooled `-pooler` endpoint runs PgBouncer in
  transaction mode, incompatible with asyncpg's server-side prepared statements),
  `DB_LAMBDA_POOLING` (NullPool — let Neon's own pooler own connection reuse instead of
  SQLAlchemy holding idle connections per Lambda container).
- **`S3CrudPolicy` scoped to the media bucket.** The Lambda execution role had zero S3
  permissions before this was added — `storage.py`'s `boto3` calls would otherwise fail
  with `AccessDenied`.

## Troubleshooting quick reference

- **`ROLLBACK_COMPLETE` stack status** — CloudFormation can't update from this state.
  Delete first, then redeploy: `aws cloudformation delete-stack --stack-name
  graph-rag-backend ...` then `aws cloudformation wait stack-delete-complete ...`.
- **Git Bash mangles absolute-looking paths** (`/aws/lambda/...`, `/tmp/...`) into
  Windows paths and back, silently breaking `aws logs tail`/`sam local invoke` calls.
  Prefix the command with `export MSYS_NO_PATHCONV=1` for AWS CLI calls that take
  logical (non-filesystem) strings like log group names or ARNs. For real file paths
  passed to Windows-native tools (`sam.cmd`), do the opposite — let the conversion
  happen, or use an explicit Windows-style path.
- **Reading Lambda logs**: `aws logs tail "/aws/lambda/<function-name>" --since 10m
  --region ap-northeast-2 --profile my-ai-app` (with `MSYS_NO_PATHCONV=1`).
- **Checking the IAM role actually attached**: the SAM-generated role name isn't the
  logical ID — resolve it first (`describe-stack-resource` on `GraphRagFunctionRole`),
  then `aws iam list-role-policies` / `get-role-policy`.
