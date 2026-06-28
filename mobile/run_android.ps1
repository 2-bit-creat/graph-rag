# Physical Android dev launcher (wireless or USB).
param(
    [Parameter(Mandatory = $true)]
    [string]$ApiBaseUrl
)

$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

Write-Host ""
Write-Host "[run_android] Starting Flutter Android app..." -ForegroundColor Cyan
Write-Host "[run_android] API: $ApiBaseUrl" -ForegroundColor Cyan
Write-Host ""

function Get-AdbDeviceSerial {
    adb start-server | Out-Null
    $serials = @(adb devices 2>&1 |
        Where-Object { $_ -is [string] -and $_ -match '^\S+\s+device$' } |
        ForEach-Object { ($_ -split '\s+', 2)[0].Trim() })

    if ($serials.Count -eq 0) {
        Write-Host "[run_android] ERROR: No Android device connected via adb." -ForegroundColor Red
        Write-Host ""
        Write-Host "  adb kill-server && adb start-server && adb devices" -ForegroundColor Yellow
        Write-Host "  (USB cable or setup_android_wifi.bat first)" -ForegroundColor Yellow
        Write-Host ""
        exit 1
    }

    return $serials[0]
}

function Test-AdbConnection {
    param([string]$Serial)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $echo = (& adb -s $Serial shell echo ok 2>&1 | Out-String).Trim()
        $sdk = (& adb -s $Serial shell getprop ro.build.version.sdk 2>&1 | Out-String).Trim()
        return @{
            Ok = ($echo -eq 'ok')
            Sdk = $sdk
        }
    }
    finally {
        $ErrorActionPreference = $prev
    }
}

function Get-FlutterAndroidDeviceId {
    param([string]$PreferredSerial)

    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $raw = (& flutter devices --machine 2>&1 | Out-String).Trim()
        if ([string]::IsNullOrWhiteSpace($raw)) {
            return $null
        }
        $devices = @($raw | ConvertFrom-Json)
        if ($devices.Count -eq 0) {
            return $null
        }

        $supported = @($devices | Where-Object {
                ($_.platformType -eq 'android' -or "$($_.targetPlatform)" -like 'android*') -and
                $_.isSupported -eq $true
            })

        if ($supported.Count -eq 0) {
            return $null
        }

        $match = $supported | Where-Object { $_.id -eq $PreferredSerial } | Select-Object -First 1
        if ($match) {
            return $match.id
        }

        return $supported[0].id
    }
    catch {
        return $null
    }
    finally {
        $ErrorActionPreference = $prev
    }
}

$serial = Get-AdbDeviceSerial
Write-Host "[run_android] adb device: $serial" -ForegroundColor Cyan

$conn = Test-AdbConnection -Serial $serial
if (-not $conn.Ok) {
    Write-Host "[run_android] ERROR: adb lists the phone but the connection is broken." -ForegroundColor Red
    Write-Host ""
    Write-Host "Try this:" -ForegroundColor Yellow
    Write-Host "  1. Unlock phone screen"
    Write-Host "  2. USB mode: File transfer (MTP), not charge-only"
    Write-Host "  3. adb kill-server && adb start-server"
    Write-Host "  4. Unplug/replug USB cable"
    Write-Host "  5. adb -s $serial shell echo ok   (must print: ok)"
    Write-Host ""
    exit 1
}

if ($conn.Sdk -match '^\d+$') {
    Write-Host "[run_android] Device SDK level: $($conn.Sdk)" -ForegroundColor DarkGray
}

try {
    flutter pub get
    if ($LASTEXITCODE -ne 0) { throw "flutter pub get failed (exit $LASTEXITCODE)" }

    $flutterDevice = Get-FlutterAndroidDeviceId -PreferredSerial $serial
    if (-not $flutterDevice) {
        Write-Host "[run_android] ERROR: Flutter cannot see a supported Android device." -ForegroundColor Red
        Write-Host ""
        Write-Host "adb is connected but Flutter does not support this device yet." -ForegroundColor Yellow
        Write-Host "Run manually and check output:" -ForegroundColor Yellow
        Write-Host "  flutter devices"
        Write-Host "  adb -s $serial shell getprop ro.product.model"
        Write-Host ""
        Write-Host "Then retry after unlocking the phone and replugging USB." -ForegroundColor Yellow
        exit 1
    }

    Write-Host "[run_android] flutter device: $flutterDevice" -ForegroundColor Cyan
    flutter run -d $flutterDevice --dart-define=API_BASE_URL=$ApiBaseUrl
    if ($LASTEXITCODE -ne 0) { throw "flutter run failed (exit $LASTEXITCODE)" }
}
catch {
    Write-Host ""
    Write-Host "[run_android] ERROR: $_" -ForegroundColor Red
    exit 1
}
