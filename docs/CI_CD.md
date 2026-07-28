# Git push production deployment

`main`에 push하면 GitHub Actions가 backend test, Flutter test/build, SAM
validation을 수행한 뒤 Lambda/DB와 Flutter Web을 배포합니다. 운영 배포는 한 번에
하나만 실행되고 실패하면 GitHub Actions의 job summary와 `deploy-diagnostics`
artifact에서 CloudFormation 이벤트와 마스킹된 Lambda 로그를 확인할 수 있습니다.

## One-time setup

이 절차는 `.env`, `.env.*`, `.deploy-secrets.env`를 읽거나 수정하지 않습니다.

1. AWS CloudShell 또는 PowerShell에서 현재 Lambda의 physical function name을 확인하고
   `scripts/bootstrap_secret_from_lambda.ps1`를 실행한다. 이 스크립트는 기존 Lambda
   환경의 세 운영값을 AWS 내부에서 `graph-rag/prod/app`으로 복사하고 값 자체를
   출력하지 않는다. 이미 Secret이 있다면 중단되므로 overwrite하지 않는다.
2. `infra/github-oidc-bootstrap.yaml`을 한 번 배포한다. 입력값은 GitHub 조직/저장소,
   Web S3 bucket, Web CloudFront distribution ID다. 출력 `DeployRoleArn`을 GitHub
   `production` Environment variable `AWS_DEPLOY_ROLE_ARN`에 넣는다.
3. 같은 GitHub Environment에 다음 **공개 식별자** Variables를 넣는다.

   - `WEB_BUCKET`
   - `WEB_DISTRIBUTION_ID`
   - `WEB_ORIGIN`
   - `MEDIA_BUCKET`
   - `MEDIA_BASE_URL`
   - `API_BASE_URL` (frontend-only 재배포 시에만 사용)

4. GitHub `production` Environment의 deployment branch를 `main`으로 제한한다.
5. 첫 workflow는 `live` alias를 생성하되 canary 없이 끝난다. 다음 `main` push부터는
   PreTraffic migration/readiness 검사 후 `Canary10Percent5Minutes`로 전환된다.

## DB migration policy

새 자동 migration은 `backend/migrations/versions/NNNN_description.sql`에 추가한다.
자동 허용 범위는 새 table/index와 `ALTER TABLE ... ADD COLUMN|ADD CONSTRAINT`뿐이다.
기존 migration을 수정하면 checksum 불일치로 배포가 중단된다. DROP, rename, 타입
변경, NOT NULL 강화, 데이터 backfill은 자동 push 배포에서 의도적으로 거부된다.

## Debugging

`/health`는 프로세스 liveness, `/ready`는 DB 연결·schema version·commit version을
비밀값 없이 반환한다. CodeDeploy PreTraffic 실패는 `DeploymentValidationHook` 로그와
새 Lambda version 로그를 확인한다. 진단 스크립트는 Lambda 환경변수나 Secrets Manager
값을 조회하지 않는다.
