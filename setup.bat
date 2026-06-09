@echo off
setlocal enabledelayedexpansion
rem ============================================================================
rem  TurboBitQuant - One-shot environment bootstrap (Windows)
rem ----------------------------------------------------------------------------
rem  Detects and installs everything needed to build and run TurboBitQuant:
rem    - Python 3 (+ Flask, requests, huggingface_hub)
rem    - CMake
rem    - Visual Studio C++ toolchain (detected via vswhere; installed if missing)
rem    - Rust / Cargo  (only when building the Tauri desktop app)
rem    - The llama.cpp Ternary/TurboQuant fork (clone + compile)
rem
rem  Usage:
rem    setup.bat                 Full setup: toolchain + llama.cpp build
rem    setup.bat --with-tauri    Also install Rust and build the desktop app
rem    setup.bat --with-model    Also download a small starter GGUF model
rem    setup.bat --check         Detection only; install nothing
rem
rem  Re-runnable: each step is skipped when already satisfied.
rem ============================================================================

set "WITH_TAURI=0"
set "WITH_MODEL=0"
set "CHECK_ONLY=0"
for %%A in (%*) do (
    if /i "%%~A"=="--with-tauri" set "WITH_TAURI=1"
    if /i "%%~A"=="--with-model" set "WITH_MODEL=1"
    if /i "%%~A"=="--check"      set "CHECK_ONLY=1"
)

set "ROOT=%~dp0"
cd /d "%ROOT%"
set "FAIL=0"

echo ============================================================
echo  TurboBitQuant Setup
echo  Root: %ROOT%
if "%CHECK_ONLY%"=="1" echo  Mode: DETECTION ONLY (no installs)
echo ============================================================

rem --- winget availability (needed for any auto-install) ---------------------
where winget >nul 2>nul
if %errorlevel% neq 0 (
    set "HAVE_WINGET=0"
    echo [!] winget not found - automatic installs are unavailable.
    echo [!] Install tools manually or install "App Installer" from the Microsoft Store.
) else (
    set "HAVE_WINGET=1"
)

rem ===========================================================================
echo.
echo [1/6] Python
echo ------------------------------------------------------------
call :need_python
if "%HAVE_PY%"=="1" (
    echo [+] Python found: !PY_CMD!
) else (
    echo [-] Python not found ^(or only the Microsoft Store stub is present^).
    call :maybe_install "Python.Python.3.12" "machine" "Python 3.12"
    rem Refresh PATH so the freshly installed python is visible this session
    call :refresh_path
    call :need_python
    if "!HAVE_PY!"=="1" ( echo [+] Python installed: !PY_CMD! ) else ( echo [-] Python still not detected. & set "FAIL=1" )
)

rem ===========================================================================
echo.
echo [2/6] CMake
echo ------------------------------------------------------------
where cmake >nul 2>nul
if %errorlevel% equ 0 (
    echo [+] CMake found.
) else (
    echo [-] CMake not found.
    call :maybe_install "Kitware.CMake" "machine" "CMake"
    call :refresh_path
    where cmake >nul 2>nul
    if !errorlevel! equ 0 ( echo [+] CMake installed. ) else ( echo [-] CMake still not detected. & set "FAIL=1" )
)

rem ===========================================================================
echo.
echo [3/6] Visual Studio C++ toolchain
echo ------------------------------------------------------------
call :find_vs
if defined VCVARS (
    echo [+] MSVC toolchain found: !VS_NAME!
    echo     vcvars: !VCVARS!
) else (
    echo [-] No Visual Studio C++ toolchain detected.
    call :maybe_install "Microsoft.VisualStudio.2022.BuildTools" "machine" "VS 2022 Build Tools (C++ workload)" "--quiet --wait --norestart --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended"
    call :find_vs
    if defined VCVARS ( echo [+] MSVC toolchain installed: !VS_NAME! ) else ( echo [-] MSVC toolchain still not detected. & set "FAIL=1" )
)

rem ===========================================================================
echo.
echo [4/6] Python dependencies (Flask, requests)
echo ------------------------------------------------------------
if "%CHECK_ONLY%"=="1" (
    echo [i] Skipped in --check mode.
) else if "%HAVE_PY%"=="1" (
    echo [*] Installing/upgrading pip packages...
    !PY_CMD! -m pip install --upgrade pip >nul 2>nul
    !PY_CMD! -m pip install Flask requests
    if !errorlevel! equ 0 ( echo [+] Flask and requests ready. ) else ( echo [-] pip install failed. & set "FAIL=1" )
) else (
    echo [-] Skipped: Python unavailable.
    set "FAIL=1"
)

rem ===========================================================================
echo.
echo [5/6] llama.cpp backend (clone + compile)
echo ------------------------------------------------------------
if "%CHECK_ONLY%"=="1" (
    echo [i] Skipped in --check mode.
) else (
    if exist "bin\llama-server.exe" (
        echo [+] bin\llama-server.exe already present - skipping build.
    ) else (
        if not exist "llama.cpp\CMakeLists.txt" (
            echo [*] Cloning llama.cpp fork...
            "!PY_CMD!" setup_backend.py
        ) else (
            echo [+] llama.cpp source already present.
        )
        echo [*] Compiling C++ binaries (this can take several minutes)...
        call build.bat
        if exist "bin\llama-server.exe" (
            echo [+] Build succeeded: bin\llama-server.exe
        ) else (
            echo [-] Build did not produce bin\llama-server.exe.
            set "FAIL=1"
        )
    )
)

rem ===========================================================================
echo.
echo [6/6] Optional components
echo ------------------------------------------------------------
if "%WITH_TAURI%"=="1" (
    echo [*] Tauri desktop app requested.
    where cargo >nul 2>nul
    if !errorlevel! neq 0 (
        echo [-] Rust/Cargo not found.
        call :maybe_install "Rustlang.Rustup" "user" "Rust (rustup)"
        call :refresh_path
        if exist "%USERPROFILE%\.cargo\bin" set "PATH=%PATH%;%USERPROFILE%\.cargo\bin"
    )
    where cargo >nul 2>nul
    if !errorlevel! equ 0 (
        echo [+] Cargo found.
        if "%CHECK_ONLY%"=="0" (
            echo [*] Building Tauri app ^(release^)...
            cargo build --release --manifest-path src-tauri\Cargo.toml
            if !errorlevel! equ 0 ( echo [+] Tauri build succeeded. ) else ( echo [-] Tauri build failed. & set "FAIL=1" )
        )
    ) else (
        echo [-] Cargo still not detected.
        set "FAIL=1"
    )
) else (
    echo [i] Tauri build not requested ^(pass --with-tauri to enable^).
)

if "%WITH_MODEL%"=="1" (
    if "%CHECK_ONLY%"=="0" if "%HAVE_PY%"=="1" (
        echo [*] Downloading starter model ^(Qwen2.5-0.5B, Q4_K_M^)...
        "!PY_CMD!" download_models.py --model Qwen-0.5B --quant Q4_K_M
    )
) else (
    echo [i] Model download not requested ^(pass --with-model to fetch a starter GGUF^).
)

rem ===========================================================================
echo.
echo ============================================================
if "%FAIL%"=="0" (
    echo  SETUP COMPLETE
    echo  Start the app with:   python host.py
    echo  Then open:            http://localhost:5000/
) else (
    echo  SETUP FINISHED WITH ISSUES - review the [-] lines above.
)
echo ============================================================
exit /b %FAIL%

rem ===========================================================================
rem  Subroutines
rem ===========================================================================

:need_python
rem Sets HAVE_PY=1 and PY_CMD if a *real* python (not the Store stub) is present.
set "HAVE_PY=0"
set "PY_CMD="
for %%P in (py python python3) do (
    if not defined PY_CMD (
        %%P -c "import sys" >nul 2>nul
        if !errorlevel! equ 0 (
            set "PY_CMD=%%P"
            set "HAVE_PY=1"
        )
    )
)
exit /b 0

:find_vs
rem Sets VCVARS and VS_NAME using vswhere (covers Community/Pro/Enterprise/BuildTools).
set "VCVARS="
set "VS_NAME="
set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
if not exist "!VSWHERE!" exit /b 0
for /f "usebackq tokens=*" %%i in (`"!VSWHERE!" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath 2^>nul`) do (
    if exist "%%i\VC\Auxiliary\Build\vcvars64.bat" (
        set "VCVARS=%%i\VC\Auxiliary\Build\vcvars64.bat"
        set "VS_NAME=%%i"
    )
)
exit /b 0

:maybe_install
rem %1=winget id  %2=scope(machine/user)  %3=label  %4=optional --override string
if "%CHECK_ONLY%"=="1" (
    echo [i] --check mode: would install %~3 ^(%~1^).
    exit /b 0
)
if "%HAVE_WINGET%"=="0" (
    echo [-] Cannot auto-install %~3 - winget unavailable.
    exit /b 1
)
echo [*] Installing %~3 via winget...
if "%~4"=="" (
    winget install --id %~1 -e --source winget --accept-package-agreements --accept-source-agreements --scope %~2
) else (
    winget install --id %~1 -e --source winget --accept-package-agreements --accept-source-agreements --override "%~4"
)
exit /b 0

:refresh_path
rem Reloads PATH from the registry (machine + user) into this session.
for /f "usebackq tokens=2,*" %%a in (`reg query "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Environment" /v Path 2^>nul ^| findstr /i "Path"`) do set "MPATH=%%b"
for /f "usebackq tokens=2,*" %%a in (`reg query "HKCU\Environment" /v Path 2^>nul ^| findstr /i "Path"`) do set "UPATH=%%b"
set "PATH=%MPATH%;%UPATH%"
exit /b 0
