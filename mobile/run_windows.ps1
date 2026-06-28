# Windows desktop dev launcher (VS2019 + CMake 3.20 compatible).
param(
    [string]$ApiBaseUrl = "http://localhost:8000"
)

$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

Write-Host ""
Write-Host "[run_windows] Starting Flutter Windows app..." -ForegroundColor Cyan
Write-Host "[run_windows] API: $ApiBaseUrl" -ForegroundColor Cyan
Write-Host ""

try {
    flutter pub get
    if ($LASTEXITCODE -ne 0) { throw "flutter pub get failed (exit $LASTEXITCODE)" }

    & powershell -ExecutionPolicy Bypass -File "$PSScriptRoot\tool\patch_record_windows_cmake.ps1"
    if ($LASTEXITCODE -ne 0) { throw "CMake patch failed (exit $LASTEXITCODE)" }

    flutter run -d windows --dart-define=API_BASE_URL=$ApiBaseUrl
    if ($LASTEXITCODE -ne 0) { throw "flutter run failed (exit $LASTEXITCODE)" }
}
catch {
    Write-Host ""
    Write-Host "[run_windows] ERROR: $_" -ForegroundColor Red
    exit 1
}
