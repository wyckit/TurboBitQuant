# TurboBitQuant iOS App

This is a native iOS application built using **SwiftUI** that runs GGUF models directly on iPhones and iPads using `llama.cpp` with hardware-accelerated **Metal** GPU execution. 

It does not require a desktop host, active network connection, or local proxy servers; inference is performed entirely in-process on-device.

---

## Technical Architecture

* **UI Layer**: A modern SwiftUI interface featuring a glassmorphic sidebar, model selector, Hugging Face search interface, and custom message rendering view.
* **Inference Engine**: Written in Swift, interfacing directly with the `llama.cpp` C++ API in-process. 
* **Acceleration**: Metal API is automatically enabled for prompt evaluation and token generation on Apple Silicon GPUs (A-series/M-series chips).

---

## Build Prerequisites

To compile and install the application, you need:

1. **A macOS Machine** running macOS 14 (Sonoma) or newer.
2. **Xcode** (Version 15.0 or newer).
3. **Rust Toolchain** (if compiling Tauri dependencies, though the native iOS app targets native C++ and Swift).
4. An **Apple Developer Account** (free personal account is sufficient for sideloading onto your personal device).

---

## Getting Started

### 1. Open the Xcode Project
1. Open **Xcode**.
2. Select **Open Existing Project** and choose the `ios/` folder or double-click the `TurboBitQuant.xcodeproj` once generated.

### 2. Linking `llama.cpp` Dependency
To link the specialized ternary/turboquant `llama.cpp` engine:
1. In Xcode, select the **TurboBitQuant** project root in the left sidebar.
2. Go to the **Package Dependencies** tab.
3. Click the **+** button.
4. Add the repository: `https://github.com/LyndonBlack/llama.cpp-Ternary-1.58Bit-and-TurboQuant.git` (or point to the local `llama.cpp` repository submodule).
5. Choose the target branch/commit matching the desktop setup.
6. Link the `llama` target to the **TurboBitQuant** app binary.

### 3. Signing the Application
1. In Xcode, select the **TurboBitQuant** target.
2. Navigate to the **Signing & Capabilities** tab.
3. Check **Automatically manage signing**.
4. Choose your **Team** (Apple ID / Personal Team).
5. Change the **Bundle Identifier** to a unique value (e.g., `com.yourname.turbobitquant.app`).

### 4. Deploying to Device
1. Connect your iPhone/iPad to the Mac via USB.
2. In your device settings, go to **Settings** > **Privacy & Security** > **Developer Mode** and enable it (requires device restart).
3. In Xcode, select your connected device in the target device selector (top bar).
4. Click **Run** (Command + R) to compile and install.
5. On the phone, go to **Settings** > **General** > **VPN & Device Management**, select your developer profile, and tap **Trust**.

---

## Running Models on iPhone/iPad

1. Launch **TurboBitQuant** on your device.
2. Go to the **Model Hub** tab to search Hugging Face or select a GGUF file from your device storage using the system file picker.
   * *Tip: For mobile devices, prefer small models (e.g., Qwen-2.5-0.5B, Qwen-2.5-1.5B, or Gemma-2B quantized to Q4_K_M) to avoid out-of-memory crashes.*
3. Select your context size and click **Load**.
4. Once loaded, switch to the **Chat Suite** and run hardware-accelerated local inference!
