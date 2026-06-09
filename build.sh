#!/usr/bin/env bash
# TurboBitQuant - macOS/Linux compilation script

set -e

BACKEND_DIR="llama.cpp"
BUILD_DIR="build"
BIN_DIR="bin"

echo "[*] Compilation script started..."

if [ ! -d "$BACKEND_DIR" ]; then
    echo "[-] Error: C++ backend repository '$BACKEND_DIR' not found. Please run 'python3 setup_backend.py' first."
    exit 1
fi

# Check if cmake is installed
if ! command -v cmake &> /dev/null; then
    echo "[-] Error: 'cmake' is not installed or not in PATH."
    echo "[-] Please install cmake (e.g. 'brew install cmake' on Mac or 'sudo apt install cmake' on Ubuntu)."
    exit 1
fi

# Detect platform
PLATFORM="$(uname -s)"
echo "[*] Platform detected: $PLATFORM"

CMAKE_FLAGS=("-DCMAKE_BUILD_TYPE=Release")

if [ "$PLATFORM" = "Darwin" ]; then
    echo "[*] Configuring build for macOS (Metal acceleration)..."
    CMAKE_FLAGS+=("-DGGML_METAL=ON" "-DLLAMA_METAL=ON")
elif [ "$PLATFORM" = "Linux" ]; then
    echo "[*] Checking for CUDA on Linux..."
    if command -v nvcc &> /dev/null; then
        echo "[+] CUDA compiler found. Building with GPU acceleration..."
        CMAKE_FLAGS+=("-DGGML_CUDA=ON" "-DLLAMA_CUDA=ON")
    else
        echo "[!] CUDA compiler not found. Defaulting to CPU-only build."
    fi
else
    echo "[!] Unknown Unix platform. Proceeding with default CPU build config."
fi

cd "$BACKEND_DIR"

echo "[*] Creating build directory..."
mkdir -p "$BUILD_DIR"

echo "[*] Running CMake with flags: ${CMAKE_FLAGS[*]}"
cmake -B "$BUILD_DIR" -S . "${CMAKE_FLAGS[@]}"

echo "[*] Compiling binaries..."
# Use all available CPU cores for faster build
CORES=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)
cmake --build "$BUILD_DIR" --config Release -j "$CORES"

cd ..

# Create binary directory
mkdir -p "$BIN_DIR"

# Copy binaries to root bin folder
echo "[*] Copying compiled executables..."
BUILT_BIN_DIR="$BACKEND_DIR/$BUILD_DIR/bin"

# Locate the files (llama-cli/llama-quantize, etc.)
FILES_TO_COPY=("llama-cli" "llama-quantize" "llama-server" "main" "quantize" "server")

COPIED_ANY=false
for file in "${FILES_TO_COPY[@]}"; do
    # Search in common build structures
    SRC_PATH=""
    if [ -f "$BUILT_BIN_DIR/$file" ]; then
        SRC_PATH="$BUILT_BIN_DIR/$file"
    elif [ -f "$BACKEND_DIR/$BUILD_DIR/$file" ]; then
        SRC_PATH="$BACKEND_DIR/$BUILD_DIR/$file"
    fi

    if [ -n "$SRC_PATH" ]; then
        echo "[+] Copying $file to $BIN_DIR/$file"
        cp "$SRC_PATH" "$BIN_DIR/$file"
        chmod +x "$BIN_DIR/$file"
        COPIED_ANY=true
    fi
done

if [ "$COPIED_ANY" = false ]; then
    echo "[!] Warning: No executables were found in the build directory. Compilation might have failed or outputs were placed in a different location."
    echo "[*] Please check the output logs in: $BACKEND_DIR/$BUILD_DIR"
else
    echo "[+] Compilation and setup completed successfully! Executables are available in ./$BIN_DIR/"
fi
