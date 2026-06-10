param(
    [ValidateSet("Debug", "Release")]
    [string]$Configuration = "Debug"
)

$ErrorActionPreference = "Stop"

$androidDir = Join-Path $PSScriptRoot "android"
$gradlew = Join-Path $androidDir "gradlew.bat"

if (-not (Test-Path $gradlew)) {
    throw "Missing Gradle wrapper: $gradlew"
}

if (-not $env:ANDROID_HOME) {
    throw "ANDROID_HOME is not set. Install Android Studio and set ANDROID_HOME to your Android SDK directory."
}

if (-not $env:JAVA_HOME) {
    throw "JAVA_HOME is not set. Use Android Studio's bundled JBR or another Java 17+ JDK."
}

$oldErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = "Continue"
$javaVersionOutput = & "$env:JAVA_HOME\bin\java.exe" -version 2>&1
$ErrorActionPreference = $oldErrorActionPreference
if ($LASTEXITCODE -ne 0) {
    throw "Could not run Java from JAVA_HOME: $env:JAVA_HOME"
}

$javaVersionText = $javaVersionOutput -join " "
if ($javaVersionText -notmatch '"(?<major>\d+)\.' -or [int]$Matches.major -lt 17) {
    throw "Java 17+ is required by the Android Gradle plugin. Current output: $javaVersionText"
}

$task = if ($Configuration -eq "Release") { "assembleRelease" } else { "assembleDebug" }
$log = Join-Path $androidDir "build\last-$($task).log"
New-Item -ItemType Directory -Force (Split-Path $log -Parent) | Out-Null
Push-Location $androidDir
try {
    $gradleOutput = & $gradlew $task --console=plain 2>&1
    $gradleExitCode = $LASTEXITCODE
    $gradleOutput | Set-Content -LiteralPath $log
    $gradleOutput | Write-Output
    if ($gradleExitCode -ne 0 -or ($gradleOutput -match "BUILD FAILED")) {
        throw "Gradle build failed. See log: $log"
    }
}
finally {
    Pop-Location
}

$variant = $Configuration.ToLowerInvariant()
$apk = Join-Path $androidDir "app\build\outputs\apk\$variant\app-$variant.apk"
if (Test-Path $apk) {
    Write-Host "APK built: $apk"
} else {
    Write-Warning "Build completed but APK was not found at expected path: $apk"
}
