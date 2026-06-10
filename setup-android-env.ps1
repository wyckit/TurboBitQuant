$ErrorActionPreference = "Stop"

function Test-PathValue($PathValue) {
    return -not [string]::IsNullOrWhiteSpace($PathValue) -and (Test-Path $PathValue)
}

function Get-JavaMajorVersion($JavaExe) {
    if (-not (Test-Path $JavaExe)) {
        return $null
    }

    $oldErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $output = & $JavaExe -version 2>&1
    $ErrorActionPreference = $oldErrorActionPreference
    if ($LASTEXITCODE -ne 0) {
        return $null
    }

    $line = ($output | Select-Object -First 1)
    if ($line -match '"(?<major>\d+)\.') {
        return [int]$Matches.major
    }
    return $null
}

$defaultAndroidHome = Join-Path $env:LocalAppData "Android\Sdk"
$defaultAndroidStudio = "C:\Program Files\Android\Android Studio"
$defaultJavaHome = Join-Path $defaultAndroidStudio "jbr"

$androidHome = if (Test-PathValue $env:ANDROID_HOME) { $env:ANDROID_HOME } elseif (Test-Path $defaultAndroidHome) { $defaultAndroidHome } else { $null }
$javaHome = if (Test-PathValue $env:JAVA_HOME) { $env:JAVA_HOME } elseif (Test-Path $defaultJavaHome) { $defaultJavaHome } else { $null }
$ndkHome = if (Test-PathValue $env:NDK_HOME) {
    $env:NDK_HOME
} elseif ($androidHome -and (Test-Path (Join-Path $androidHome "ndk"))) {
    Get-ChildItem -Directory (Join-Path $androidHome "ndk") | Sort-Object Name -Descending | Select-Object -First 1 -ExpandProperty FullName
} else {
    $null
}

$javaMajor = if ($javaHome) { Get-JavaMajorVersion (Join-Path $javaHome "bin\java.exe") } else { $null }
$androidHomeDisplay = if ($androidHome) { $androidHome } else { "<missing>" }
$ndkHomeDisplay = if ($ndkHome) { $ndkHome } else { "<missing>" }
$javaHomeDisplay = if ($javaHome) { $javaHome } else { "<missing>" }
$javaMajorDisplay = if ($javaMajor) { $javaMajor } else { "<missing>" }

Write-Host "Android build environment check"
Write-Host "ANDROID_HOME: $androidHomeDisplay"
Write-Host "NDK_HOME:     $ndkHomeDisplay"
Write-Host "JAVA_HOME:    $javaHomeDisplay"
Write-Host "Java major:   $javaMajorDisplay"
Write-Host ""

$missing = @()
if (-not $androidHome) { $missing += "Android SDK" }
if (-not $ndkHome) { $missing += "Android NDK side-by-side" }
if (-not $javaHome -or -not $javaMajor -or $javaMajor -lt 17) { $missing += "Java 17+ JDK" }

if ($missing.Count -gt 0) {
    Write-Host "Missing prerequisites:" -ForegroundColor Yellow
    $missing | ForEach-Object { Write-Host " - $_" -ForegroundColor Yellow }
    Write-Host ""
    Write-Host "Install Android Studio, then in Android Studio open:"
    Write-Host "  More Actions -> SDK Manager -> SDK Tools"
    Write-Host "Install:"
    Write-Host "  Android SDK Platform-Tools"
    Write-Host "  Android SDK Build-Tools"
    Write-Host "  Android SDK Command-line Tools"
    Write-Host "  NDK (Side by side), version 29.0.13113456 if available"
    Write-Host ""
    Write-Host "After installing, restart PowerShell or run these commands with your actual paths:"
    Write-Host '[System.Environment]::SetEnvironmentVariable("ANDROID_HOME", "$env:LocalAppData\Android\Sdk", "User")'
    Write-Host '[System.Environment]::SetEnvironmentVariable("JAVA_HOME", "C:\Program Files\Android\Android Studio\jbr", "User")'
    Write-Host '$VERSION = Get-ChildItem -Name "$env:LocalAppData\Android\Sdk\ndk" | Select-Object -Last 1'
    Write-Host '[System.Environment]::SetEnvironmentVariable("NDK_HOME", "$env:LocalAppData\Android\Sdk\ndk\$VERSION", "User")'
    exit 1
}

[System.Environment]::SetEnvironmentVariable("ANDROID_HOME", $androidHome, "User")
[System.Environment]::SetEnvironmentVariable("NDK_HOME", $ndkHome, "User")
[System.Environment]::SetEnvironmentVariable("JAVA_HOME", $javaHome, "User")

$env:ANDROID_HOME = $androidHome
$env:NDK_HOME = $ndkHome
$env:JAVA_HOME = $javaHome

Write-Host "Android build environment is ready for this session and saved to User environment variables."
