@echo off
setlocal enabledelayedexpansion
rem TurboBitQuant - Windows compilation script

set BACKEND_DIR=llama.cpp
set BUILD_DIR=build
set BIN_DIR=bin

echo [*] Compilation script started for Windows...

if not exist "%BACKEND_DIR%" (
    echo [-] Error: C++ backend repository '%BACKEND_DIR%' not found. Please run 'python setup_backend.py' first.
    exit /b 1
)

rem Check if cmake is installed
where cmake >nul 2>nul
if %errorlevel% neq 0 (
    echo [-] Error: 'cmake' is not installed or not in PATH.
    echo [-] Please install CMake (https://cmake.org/download/) and add it to your PATH.
    exit /b 1
)

rem Check for Visual Studio MSVC environment
where cl >nul 2>nul
if %errorlevel% neq 0 (
    echo [*] Checking for Visual Studio Build Tools location...
    rem Check common Visual Studio install paths
    set VS_PATH=""
    if exist "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat" (
        set VS_PATH="C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat"
    ) else if exist "C:\Program Files (x86)\Microsoft Visual Studio\2019\Community\VC\Auxiliary\Build\vcvars64.bat" (
        set VS_PATH="C:\Program Files (x86)\Microsoft Visual Studio\2019\Community\VC\Auxiliary\Build\vcvars64.bat"
    ) else if exist "C:\Program Files\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat" (
        set VS_PATH="C:\Program Files\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
    )

    if not !VS_PATH! == "" (
        echo [+] Found Visual Studio environment at !VS_PATH!. Initializing x64 build tools...
        call !VS_PATH!
    ) else (
        echo [!] Warning: Visual Studio compiler 'cl.exe' not found.
        echo [!] Attempting to run cmake anyway; it might discover your compiler automatically.
    )
)

rem Check if CUDA is available
set CUDA_FLAGS=
where nvcc >nul 2>nul
if %errorlevel% equ 0 (
    echo [+] CUDA (nvcc) detected. Building with CUDA acceleration...
    set CUDA_FLAGS=-DGGML_CUDA=ON -DLLAMA_CUDA=ON
) else (
    echo [!] CUDA not detected. Building CPU-only version.
)

cd %BACKEND_DIR%

if not exist "%BUILD_DIR%" mkdir %BUILD_DIR%

echo [*] Configuring build with CMake...
cmake -B %BUILD_DIR% -S . -DCMAKE_BUILD_TYPE=Release %CUDA_FLAGS%

echo [*] Compiling binaries...
cmake --build %BUILD_DIR% --config Release --parallel

cd ..

if not exist "%BIN_DIR%" mkdir %BIN_DIR%

echo [*] Copying compiled executables...

rem List of binaries we want to copy
set FILES=llama-cli.exe llama-quantize.exe llama-server.exe main.exe quantize.exe server.exe
set COPIED_ANY=0

for %%f in (%FILES%) do (
    set SRC_PATH=""
    if exist "%BACKEND_DIR%\%BUILD_DIR%\bin\Release\%%f" (
        set SRC_PATH="%BACKEND_DIR%\%BUILD_DIR%\bin\Release\%%f"
    ) else if exist "%BACKEND_DIR%\%BUILD_DIR%\bin\%%f" (
        set SRC_PATH="%BACKEND_DIR%\%BUILD_DIR%\bin\%%f"
    ) else if exist "%BACKEND_DIR%\%BUILD_DIR%\Release\%%f" (
        set SRC_PATH="%BACKEND_DIR%\%BUILD_DIR%\Release\%%f"
    ) else if exist "%BACKEND_DIR%\%BUILD_DIR%\%%f" (
        set SRC_PATH="%BACKEND_DIR%\%BUILD_DIR%\%%f"
    )

    if not !SRC_PATH! == "" (
        echo [+] Copying %%f to %BIN_DIR%\%%f
        copy /y !SRC_PATH! "%BIN_DIR%\%%f" >nul
        set COPIED_ANY=1
    )
)

if %COPIED_ANY% equ 0 (
    echo [!] Warning: No executables were copied. Please check the build directory.
) else (
    echo [+] Compilation and setup completed successfully! Executables are available in .\%BIN_DIR%\
)
