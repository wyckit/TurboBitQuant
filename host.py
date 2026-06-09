#!/usr/bin/env python3
"""
TurboBitQuant - Host Coordinator Server
Serves the chat frontend and coordinates starting/stopping the C++ llama-server.
"""
import os
import sys
import time
import shutil
import subprocess
import multiprocessing

def install_and_import(package):
    import importlib
    try:
        importlib.import_module(package)
    except ImportError:
        print(f"[*] Dynamic setup: '{package}' is missing. Installing...")
        subprocess.check_call([sys.executable, "-m", "pip", "install", package])

# Ensure Flask and requests are installed
install_and_import("Flask")
install_and_import("requests")

from flask import Flask, request, Response, jsonify, send_from_directory

app = Flask(__name__, static_folder="static", static_url_path="")

# Active subprocess tracker dict: { model_file: { "process": Popen, "port": int, "gpu_layers": int, "ctx_size": int } }
running_servers = {}

def cleanup_dead_servers():
    global running_servers
    dead_models = []
    for model, srv in running_servers.items():
        if srv["process"].poll() is not None:
            dead_models.append(model)
    for model in dead_models:
        print(f"[*] Cleaning up dead server for model: {model}")
        del running_servers[model]

def find_free_port(start_port=8080):
    import socket
    port = start_port
    while port < 65535:
        if any(srv["port"] == port for srv in running_servers.values()):
            port += 1
            continue
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
            try:
                s.bind(("127.0.0.1", port))
                return port
            except OSError:
                port += 1
    raise RuntimeError("No free ports available")

def find_executable():
    """Locates the compiled backend server executable."""
    ext = ".exe" if os.name == "nt" else ""
    candidates = [
        os.path.join("bin", f"llama-server{ext}"),
        os.path.join("bin", f"server{ext}"),
        os.path.join("llama.cpp", "build", "bin", f"llama-server{ext}"),
        os.path.join("llama.cpp", "build", "bin", "Release", f"llama-server{ext}"),
    ]
    for c in candidates:
        if os.path.isfile(c):
            return c
            
    import shutil
    for cmd in ["llama-server", "server"]:
        path = shutil.which(cmd)
        if path:
            return path
    return None

@app.route("/")
def serve_index():
    return send_from_directory("static", "index.html")

@app.route("/api/models", methods=["GET"])
def get_models():
    """Scans models/ directory and returns list of downloaded GGUF files."""
    model_dir = "models"
    if not os.path.exists(model_dir):
        return jsonify([])
        
    models = []
    for f in os.listdir(model_dir):
        if f.endswith(".gguf"):
            path = os.path.join(model_dir, f)
            size_gb = os.path.getsize(path) / (1024 * 1024 * 1024)
            models.append({
                "filename": f,
                "size_gb": round(size_gb, 2),
                "is_31b": any(x in f for x in ["31B", "32B", "72B", "70B", "35B", "27B", "122B", "397B"])
            })
            
    # Sort: smallest first
    models.sort(key=lambda x: x["size_gb"])
    return jsonify(models)

@app.route("/api/status", methods=["GET"])
def get_status():
    """Returns the current state of all backend model servers."""
    global running_servers
    cleanup_dead_servers()
    
    models_status = {}
    for model, srv in running_servers.items():
        import requests
        is_ready = False
        try:
            r = requests.get(f"http://localhost:{srv['port']}/health", timeout=0.2)
            is_ready = (r.status_code == 200)
        except Exception:
            pass
        models_status[model] = {
            "status": "Running" if is_ready else "Starting",
            "port": srv["port"],
            "gpu_layers": srv["gpu_layers"],
            "ctx_size": srv["ctx_size"]
        }
        
    # Backwards compatibility
    status = "Stopped"
    active_model = None
    gpu_layers = 0
    if models_status:
        active_model = list(models_status.keys())[0]
        status = models_status[active_model]["status"]
        gpu_layers = models_status[active_model]["gpu_layers"]
        
    return jsonify({
        "status": status,
        "model": active_model,
        "gpu_layers": gpu_layers,
        "running_servers": models_status
    })

@app.route("/api/start", methods=["POST"])
def start_server():
    """Launches a llama-server subprocess with the selected model."""
    global running_servers
    cleanup_dead_servers()
    
    data = request.get_json() or {}
    model_file = data.get("model")
    use_turboquant = data.get("turboquant", True)
    ctx_size = data.get("ctx_size", 4096)
    
    if not model_file:
        return jsonify({"error": "No model specified"}), 400
        
    if model_file in running_servers:
        return jsonify({
            "message": "Server is already running",
            "model": model_file,
            "port": running_servers[model_file]["port"]
        }), 200
        
    model_path = os.path.join("models", model_file)
    if not os.path.isfile(model_path):
        return jsonify({"error": f"Model file not found: {model_file}"}), 404
        
    exe_path = find_executable()
    if not exe_path:
        return jsonify({"error": "Compiled C++ backend server (llama-server) not found. Compile first."}), 500

    # Auto-adjust GPU layers based on model size to prevent out-of-memory crashes
    gpu_layers = 99
    if "72B" in model_file or "70B" in model_file:
        print(f"[*] Large 70B/72B model ({model_file}) detected. Offloading a safe subset of 18 layers to GPU to stay within Metal limits.")
        gpu_layers = 18
    elif any(x in model_file for x in ["31B", "32B", "35B", "27B"]):
        print(f"[*] Medium-large 27B-35B model ({model_file}) detected. Offloading a safe subset of 32 layers to GPU to stay within Metal limits.")
        gpu_layers = 32
    elif "122B" in model_file:
        print(f"[*] Large 122B model ({model_file}) detected. Offloading a safe subset of 10 layers to GPU.")
        gpu_layers = 10
    elif "397B" in model_file:
        print(f"[*] Extreme 397B model ({model_file}) detected. Setting to CPU-only (ngl=0).")
        gpu_layers = 0
        
    threads = max(1, multiprocessing.cpu_count() - 2)
    
    try:
        port = find_free_port(8080)
    except Exception as e:
        return jsonify({"error": f"Failed to allocate a free port: {str(e)}"}), 500
        
    # Construct subprocess parameters
    cmd = [
        exe_path,
        "-m", model_path,
        "-t", str(threads),
        "-ngl", str(gpu_layers),
        "-c", str(ctx_size),
        "--port", str(port),
    ]
    
    if use_turboquant:
        cmd.extend(["-ctk", "q4_0", "-ctv", "q4_0"])
        print("[+] TurboQuant KV Cache compression enabled.")
    else:
        print("[*] TurboQuant KV Cache compression disabled.")
    
    print(f"[*] Starting backend server on port {port}: {' '.join(cmd)}")
    
    try:
        # Start the backend server as a background process redirecting stderr to stdin
        process = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True
        )
        
        # Record running server configuration
        running_servers[model_file] = {
            "process": process,
            "port": port,
            "gpu_layers": gpu_layers,
            "ctx_size": ctx_size
        }
        
        # Wait up to 2 seconds to check if it immediately crashed
        time.sleep(2)
        if process.poll() is not None:
            stdout, _ = process.communicate()
            if model_file in running_servers:
                del running_servers[model_file]
            return jsonify({"error": "Server failed to start", "logs": stdout}), 500
            
        return jsonify({"status": "Started", "model": model_file, "gpu_layers": gpu_layers, "port": port})
        
    except Exception as e:
        if model_file in running_servers:
            del running_servers[model_file]
        return jsonify({"error": f"Failed to execute llama-server: {str(e)}"}), 500

@app.route("/api/stop", methods=["POST"])
def stop_server():
    """Terminates a running backend server process or all of them."""
    global running_servers
    cleanup_dead_servers()
    
    data = request.get_json() or {}
    model_file = data.get("model")
    
    if model_file:
        if model_file not in running_servers:
            return jsonify({"status": f"Model {model_file} is not running"})
        srv = running_servers[model_file]
        try:
            print(f"[*] Terminating backend server running model: {model_file} on port {srv['port']}")
            if srv["process"].poll() is None:
                srv["process"].terminate()
                for _ in range(3):
                    if srv["process"].poll() is not None:
                        break
                    time.sleep(1)
                else:
                    srv["process"].kill()
            del running_servers[model_file]
            return jsonify({"status": "Stopped", "model": model_file})
        except Exception as e:
            return jsonify({"error": f"Error stopping server {model_file}: {str(e)}"}), 500
    else:
        errors = []
        stopped = []
        for model in list(running_servers.keys()):
            srv = running_servers[model]
            try:
                print(f"[*] Terminating backend server running model: {model} on port {srv['port']}")
                if srv["process"].poll() is None:
                    srv["process"].terminate()
                    for _ in range(3):
                        if srv["process"].poll() is not None:
                            break
                        time.sleep(1)
                    else:
                        srv["process"].kill()
                stopped.append(model)
                del running_servers[model]
            except Exception as e:
                errors.append(f"{model}: {str(e)}")
        if errors:
            return jsonify({"error": "; ".join(errors), "stopped": stopped}), 500
        return jsonify({"status": "All Stopped", "stopped": stopped})

@app.route("/api/chat", methods=["POST"])
def proxy_chat():
    """Proxies the completions request to the correct running llama-server port."""
    import requests
    cleanup_dead_servers()
    
    req_data = request.get_json() or {}
    model_file = req_data.get("model")
    
    if not model_file:
        if running_servers:
            model_file = list(running_servers.keys())[0]
        else:
            return jsonify({"error": "Model backend is not running. Please start the server first."}), 503
            
    if model_file not in running_servers:
        return jsonify({"error": f"Model backend '{model_file}' is not running. Please start the server first."}), 503
        
    srv = running_servers[model_file]
    port = srv["port"]
    
    # Map from simple chat payload to llama-server native completion payload
    messages = req_data.get("messages", [])
    prompt = ""
    for m in messages:
        role = m.get("role", "user")
        content = m.get("content", "")
        if role == "system":
            prompt += f"<|im_start|>system\n{content}<|im_end|>\n"
        elif role == "user":
            prompt += f"<|im_start|>user\n{content}<|im_end|>\n"
        elif role == "assistant":
            prompt += f"<|im_start|>assistant\n{content}<|im_end|>\n"
            
    # Append the assistant start token to cue the answer
    prompt += "<|im_start|>assistant\n"
    
    llama_payload = {
        "prompt": prompt,
        "stream": req_data.get("stream", True),
        "n_predict": req_data.get("n_predict", 1024),
        "temperature": req_data.get("temperature", 0.7),
        "stop": ["<|im_end|>", "<|im_start|>", "<|im_end|>\n"]
    }
    
    try:
        # Request completion from llama-server on the correct port
        r = requests.post(
            f"http://localhost:{port}/completion",
            json=llama_payload,
            headers={"Content-Type": "application/json"},
            stream=True
        )
        
        # Stream the chunks back to the client
        def generate():
            for chunk in r.iter_content(chunk_size=None):
                yield chunk
                
        return Response(generate(), content_type=r.headers.get("Content-Type"))
        
    except Exception as e:
        return jsonify({"error": f"Failed to communicate with model backend on port {port}: {str(e)}"}), 500

def parse_benchmark_results(filepath="benchmark_results.md"):
    # Fallback datasets derived from local macOS hardware runs
    fallback_speeds = [
        {"model": "gemma-4-E2B-it-Q4_K_M", "load_time_sec": 0.0, "prompt_speed_ts": 499.8, "gen_speed_ts": 68.7, "avg_latency_sec": 8.89},
        {"model": "gemma-4-E4B-it-Q4_K_M", "load_time_sec": 0.0, "prompt_speed_ts": 283.5, "gen_speed_ts": 47.8, "avg_latency_sec": 12.71},
        {"model": "gemma-4-12B-it-Q4_K_M", "load_time_sec": 0.0, "prompt_speed_ts": 116.6, "gen_speed_ts": 23.6, "avg_latency_sec": 24.32},
        {"model": "gemma-4-26B-A4B-it-UD-Q4_K_M", "load_time_sec": 0.0, "prompt_speed_ts": 177.7, "gen_speed_ts": 43.6, "avg_latency_sec": 16.16},
        {"model": "gemma-4-31B-it-Q4_K_M", "load_time_sec": 0.0, "prompt_speed_ts": 11.9, "gen_speed_ts": 5.9, "avg_latency_sec": 138.18}
    ]
    fallback_memory = [
        {"context_size": 1024, "f16_mem_mb": 3145.2, "tq_mem_mb": 3135.1, "saved_mb": 10.1, "saved_pct": 0.3, "f16_gen_ts": 98.5, "tq_gen_ts": 76.9},
        {"context_size": 4096, "f16_mem_mb": 3163.0, "tq_mem_mb": 3144.1, "saved_mb": 19.0, "saved_pct": 0.6, "f16_gen_ts": 97.5, "tq_gen_ts": 78.8},
        {"context_size": 8192, "f16_mem_mb": 3185.8, "tq_mem_mb": 3154.1, "saved_mb": 31.8, "saved_pct": 1.0, "f16_gen_ts": 94.3, "tq_gen_ts": 80.9},
        {"context_size": 16384, "f16_mem_mb": 3234.2, "tq_mem_mb": 3161.3, "saved_mb": 72.9, "saved_pct": 2.3, "f16_gen_ts": 96.8, "tq_gen_ts": 79.1},
        {"context_size": 32768, "f16_mem_mb": 3329.7, "tq_mem_mb": 3196.7, "saved_mb": 133.0, "saved_pct": 4.0, "f16_gen_ts": 97.5, "tq_gen_ts": 81.4}
    ]
    
    if not os.path.exists(filepath):
        return {"speeds": fallback_speeds, "memory": fallback_memory}
        
    speeds = []
    memory = []
    current_section = None
    
    try:
        with open(filepath, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                    
                # Detect sections
                if "Speed & Efficiency Comparison" in line:
                    current_section = "speeds"
                    continue
                elif "Context Length & Memory Scaling Benchmark" in line:
                    current_section = "memory"
                    continue
                elif line.startswith("## ") and "Specialized Intelligence" in line:
                    # End parsing speeds or memory section
                    current_section = None
                    
                if line.startswith("|"):
                    parts = [p.strip() for p in line.split("|")][1:-1]
                    if not parts or len(parts) == 0:
                        continue
                    # Skip headers and separators
                    if any(x in parts[0] for x in ["Model Name", "Context Size", "---", ":---"]):
                        continue
                        
                    if current_section == "speeds" and len(parts) >= 5:
                        try:
                            model = parts[0].replace("**", "").strip()
                            load_time = float(parts[1].replace("s", "").strip())
                            prompt_speed = float(parts[2].replace("t/s", "").strip())
                            gen_speed = float(parts[3].replace("t/s", "").strip())
                            avg_latency = float(parts[4].replace("s", "").strip())
                            speeds.append({
                                "model": model,
                                "load_time_sec": load_time,
                                "prompt_speed_ts": prompt_speed,
                                "gen_speed_ts": gen_speed,
                                "avg_latency_sec": avg_latency
                            })
                        except ValueError:
                            pass
                    elif current_section == "memory" and len(parts) >= 7:
                        try:
                            ctx_size = int(parts[0].strip())
                            f16_mem = float(parts[1].replace("MB", "").strip())
                            tq_mem = float(parts[2].replace("MB", "").strip())
                            saved_mb = float(parts[3].replace("MB", "").strip())
                            
                            saved_pct_raw = parts[4].replace("%", "").replace("**", "").strip()
                            saved_pct = float(saved_pct_raw)
                            
                            f16_gen = float(parts[5].replace("t/s", "").strip())
                            tq_gen = float(parts[6].replace("t/s", "").strip())
                            memory.append({
                                "context_size": ctx_size,
                                "f16_mem_mb": f16_mem,
                                "tq_mem_mb": tq_mem,
                                "saved_mb": saved_mb,
                                "saved_pct": saved_pct,
                                "f16_gen_ts": f16_gen,
                                "tq_gen_ts": tq_gen
                            })
                        except ValueError:
                            pass
    except Exception as e:
        print(f"[-] Error parsing benchmark results: {e}")
        
    return {
        "speeds": speeds if speeds else fallback_speeds,
        "memory": memory if memory else fallback_memory
    }

@app.route("/api/benchmarks", methods=["GET"])
def get_benchmarks():
    """Returns the parsed benchmark results."""
    data = parse_benchmark_results()
    return jsonify(data)

if __name__ == "__main__":
    # Ensure static files directory exists
    os.makedirs("static", exist_ok=True)
    print("[*] Starting TurboBitQuant Host Coordinator on http://localhost:5000")
    app.run(host="0.0.0.0", port=5000, debug=True)
