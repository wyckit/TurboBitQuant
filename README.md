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

---

## Getting Started

### Prerequisites
- Python 3.9+ installed.
- Compiled `llama-server` binary inside the `bin/` directory.
- Weights stored in the `models/` directory (GGUF formats).

### Setup and Execution

1. Clone or navigate to the workspace directory.
2. Launch the backend coordinator:
   ```bash
   python3 host.py
   ```
3. Open your browser and navigate to:
   ```
   http://localhost:5000/
   ```

### Running Backend Models
- In the sidebar, select a model from the scanned list.
- Select your target context length and click **Start Server**.
- Once the status dot turns green (**Active**), go to the **Chat Suite** tab and begin chatting.

---

## Project Structure

```
├── static/
│   ├── index.html     # Glassmorphic layout dashboard
│   ├── style.css      # Thematic layouts, custom scrollbars & styling
│   └── app.js         # Frontend controller, sandbox, and API proxy bindings
├── models/            # Directory to place GGUF weights
├── bin/               # Compiled llama.cpp executables (llama-server)
├── host.py            # Flask server proxy and process manager
└── run.py             # Startup runner
```
