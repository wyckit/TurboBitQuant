# TurboBitQuant - Gemma 4 Chat Suite & Design Canvas

TurboBitQuant is a premium local LLM inference harness and frontend client built to run high-performance models (such as the Gemma 4 and Qwen 2.5 families) using hardware-accelerated C++ inference. It includes concurrent multi-model hosting, live performance benchmarks, and an interactive **Design Canvas** sandbox.

---

## Key Features

### 1. Concurrent Multi-Model Hosting
- **Dynamic Port Mapping**: Start multiple LLMs simultaneously; the backend automatically scans and maps running instances to free ports (starting from `8080`).
- **Unified Chat Client**: Switch between active running model backend servers on-the-fly using a header dropdown selector in the Chat tab.
- **Hardware-Accelerated KV Cache**: Dynamically configure context lengths (from `2K` up to `128K`) with Metal GPU acceleration and optional 4-bit TurboQuant cache compression.

### 2. Design Canvas Sandbox (HTML/CSS/JS Sandbox)
- **Live Preview Workspace**: A trial-and-error design sandbox containing side-by-side editors for **HTML5**, **CSS3**, and **JavaScript** alongside a live iframe viewport.
- **Instant Code Import**: Click "Load from Chat" to instantly extract HTML, CSS, and JS blocks from the latest assistant response in your conversation history.
- **Runtime Error Boundaries**: Includes global error catch handles inside the iframe to display JavaScript execution errors directly inside the preview panel for immediate troubleshooting.

### 3. Performance Analytics Dashboard
- Interactive charts utilizing Chart.js to map Prompt Evaluation (processing) vs. Token Generation speeds.
- RAM/VRAM cache scaling statistics across context windows.

---

## Technical Stack
- **Frontend**: Vanilla HTML5, CSS3 (glassmorphic styling, custom scrollbars, layout containers), and JavaScript (ES6+ bindings).
- **Backend Coordinator**: Flask (Python 3) tracking process lifecycles via `subprocess.Popen` and mapping requests.
- **Inference Engine**: Hardware-accelerated `llama-server` binaries built on `llama.cpp` using Metal GPU acceleration on Mac.
- **Mobile Support**:
  - **Android**: Native Kotlin app with C++ JNI bindings to run `llama.cpp` in-process. See [ANDROID.md](file:///Users/chad.sandor/TurboBitQuant/ANDROID.md).
  - **iOS**: Native SwiftUI app using in-process `llama.cpp` with Apple Metal GPU acceleration. See [ios/README.md](file:///Users/chad.sandor/TurboBitQuant/ios/README.md).

---

## Getting Started

### 1. General Desktop Web Setup (Flask & Browser)

#### Prerequisites
* Python 3.9+ installed
* Git and CMake installed
* Visual Studio Build Tools (Windows) or Developer Tools (Mac/Linux)

#### Initial Setup
1. Setup the C++ backend:
   ```bash
   python setup_backend.py
   ```
2. Build the inference engine:
   * **Windows:** `build.bat`
   * **macOS/Linux:** `bash build.sh`
3. Download test weights:
   ```bash
   python download_models.py
   ```

#### Execution
1. Launch the coordinator service:
   ```bash
   python3 host.py
   ```
2. Navigate in your browser to: `http://localhost:5000/`
3. In the sidebar, select a model, set context length, click **Start Server**, and use the **Chat Suite** tab once the status dot turns green.

---

### 2. Desktop Native App Setup (Tauri Wrapper)

#### Prerequisites
* Install [Rust](https://rustup.rs/) toolchain.
* Install the Tauri CLI tool:
  ```bash
  cargo install tauri-cli --version "^2.0.0"
  ```

#### Execution
1. From the repository root, run:
   ```bash
   cargo tauri dev
   ```
   *This automatically starts the Axum coordination server and loads the dashboard in a secure webview frame.*

---

### 3. Android Native App Setup (On-Device JNI Inference)

#### Prerequisites
* Android Studio (Koala+) & Java 17+ installed.
* Android SDK Platform, Build-Tools, and NDK version `29.0.13113456` installed.

#### Build Instructions
1. Set env variables (`JAVA_HOME`, `ANDROID_HOME`, `NDK_HOME`) manually or use the helper script:
   ```powershell
   .\setup-android-env.ps1
   ```
2. Build the debug application package:
   * **Windows (PowerShell):** `.\build-android-apk.ps1 -Configuration Debug`
   * **macOS/Linux:** `./gradlew assembleDebug` (inside the `android/` directory)
3. Install the compiled APK from `android/app/build/outputs/apk/debug/app-debug.apk` onto your device.

---

### 4. iOS Native App Setup (On-Device SwiftUI Inference)

#### Prerequisites
* macOS machine with Xcode 15.0+ installed.
* An Apple Developer account (free personal profile is sufficient).

#### Build Instructions
1. Compile the native Apple framework:
   ```bash
   cd llama.cpp
   ./build-xcframework.sh
   ```
2. Open **Xcode** and open the `/ios` project directory.
3. Link the framework target:
   - Select the **TurboBitQuant** target root.
   - Go to **Frameworks, Libraries, and Embedded Content**.
   - Drag and drop `llama.cpp/build-apple/llama.xcframework` into the list.
4. Setup your developer account in **Signing & Capabilities** and specify a unique bundle identifier.
5. Plug in your physical iOS device, enable **Developer Mode** in your phone's settings, and press **Run** (Command + R) in Xcode.

---

## Project Structure

```
├── static/
│   ├── index.html     # Glassmorphic layout dashboard
│   ├── style.css      # Thematic layouts, custom scrollbars & styling
│   └── app.js         # Frontend controller, sandbox, and API proxy bindings
├── android/           # Native Android (Kotlin/JNI) source project
├── ios/               # Native iOS (SwiftUI/Metal) source project
├── models/            # Directory to place GGUF weights
├── bin/               # Compiled llama.cpp executables (llama-server)
├── host.py            # Flask server proxy and process manager
└── run.py             # Startup runner
```
