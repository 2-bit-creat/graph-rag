# Run once with AWS credentials. It never reads local .env files or writes the
# secret value to stdout; it only transfers the existing Lambda values within AWS.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$FunctionName,
    [string]$SecretName = "graph-rag/prod/app",
    [string]$Region = "ap-northeast-2",
    [string]$Profile = "graph-rag-dev"
)

$ErrorActionPreference = "Stop"
$raw = aws lambda get-function-configuration `
    --function-name $FunctionName `
    --region $Region `
    --profile $Profile `
    --query "Environment.Variables" `
    --output json | ConvertFrom-Json

$payload = [ordered]@{
    DATABASE_URL = [string]$raw.DATABASE_URL
    OPENAI_API_KEY = [string]$raw.OPENAI_API_KEY
    JWT_SECRET = [string]$raw.JWT_SECRET
} | ConvertTo-Json -Compress

aws secretsmanager create-secret `
    --name $SecretName `
    --secret-string $payload `
    --region $Region `
    --profile $Profile `
    --output text | Out-Null

Remove-Variable raw,payload
Write-Output "Secret created without printing its value."
