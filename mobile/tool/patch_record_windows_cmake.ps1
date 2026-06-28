# Patches record_windows to build with VS2019 (CMake 3.20).
# Upstream record_windows 1.0.6+ requires CMake 3.23; Flutter on VS2019 uses 3.20.

function Patch-RecordWindowsCMake {
    param([string]$Root)

    if (-not (Test-Path $Root)) { return }

    Get-ChildItem -Path $Root -Recurse -Filter "CMakeLists.txt" -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -match "record_windows-[\d\.]+[\\/]windows[\\/]CMakeLists\.txt" } |
        ForEach-Object {
            $text = Get-Content $_.FullName -Raw
            if ($text -match 'cmake_minimum_required\(VERSION 3\.23\)') {
                $new = $text -replace 'cmake_minimum_required\(VERSION 3\.23\)', 'cmake_minimum_required(VERSION 3.14)'
                Set-Content -Path $_.FullName -Value $new -NoNewline
                Write-Host "Patched $($_.FullName)"
            }
        }
}

$pubCache = Join-Path $env:LOCALAPPDATA "Pub\Cache\hosted\pub.dev"
Patch-RecordWindowsCMake $pubCache

$mobileRoot = Split-Path $PSScriptRoot -Parent
$ephemeral = Join-Path $mobileRoot "windows\flutter\ephemeral\.plugin_symlinks"
Patch-RecordWindowsCMake $ephemeral

Write-Host "record_windows CMake patch complete."
