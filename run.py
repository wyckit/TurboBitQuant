#!/usr/bin/env python3
"""
TurboBitQuant - Model Execution Wrapper
Launches Gemma 4 models with BitNet (ternary) and TurboQuant KV-cache compression.
"""
import os
import sys
import argparse
import subprocess
import multiprocessing

def find_executable():
    """Locates the compiled backend executables in bin/ or path."""
    ext = ".exe" if os.name == "nt" else ""
    candidates = [
        os.path.join("bin", f"llama-cli{ext}"),
        os.path.join("bin", f"main{ext}"),
        os.path.join("llama.cpp", "build", "bin", f"llama-cli{ext}"),
        os.path.join("llama.cpp", "build", "bin", "Release", f"llama-cli{ext}"),
        os.path.join("llama.cpp", "build", "bin", f"main{ext}"),
        os.path.join("llama.cpp", "build", "bin", "Release", f"main{ext}"),
    ]
    
    for c in candidates:
        if os.path.isfile(c):
            return c
            
    # Try system PATH as a fallback
    import shutil
    for cmd in ["llama-cli", "main"]:
        path = shutil.which(cmd)
        if path:
            return path
            
    return None

def main():
    parser = argparse.ArgumentParser(description="Run Gemma 4 models using the compiled C++ backend with optimizations.")
    parser.add_argument(
        "--model", 
        type=str, 
        default=None,
        help="Path to the GGUF model file. If not specified, the script looks in the ./models directory."
    )
    parser.add_argument(
        "--prompt", 
        type=str, 
        default=None,
        help="One-shot prompt to execute. If not specified, launches in interactive chat mode."
    )
    parser.add_argument(
        "--turboquant", 
        action="store_true",
        default=True,
        help="Enable TurboQuant KV Cache compression (quantizes key/value cache to Q4_0). Default: True"
    )
    parser.add_argument(
        "--no-turboquant",
        action="store_false",
        dest="turboquant",
        help="Disable TurboQuant KV Cache compression (use full precision F16 for cache)."
    )
    parser.add_argument(
        "--threads", 
        type=int, 
        default=max(1, multiprocessing.cpu_count() - 2),
        help="Number of threads to use (default: CPU cores - 2)"
    )
    parser.add_argument(
        "--gpu-layers", 
        type=int, 
        default=-1,
        help="Number of layers to offload to GPU. Set to -1 for auto-optimized hybrid offloading, or 0 for CPU-only (default: -1)"
    )
    parser.add_argument(
        "--ctx-size", 
        type=int, 
        default=4096,
        help="Context window size in tokens (default: 4096)"
    )
    parser.add_argument(
        "--temp", 
        type=float, 
        default=0.7,
        help="Temperature for text generation (default: 0.7)"
    )
    parser.add_argument(
        "--n-predict", 
        type=int, 
        default=-1,
        help="Number of tokens to predict (-1 for infinite/till EOS, default: -1)"
    )
    parser.add_argument(
        "--verbose", 
        action="store_true",
        help="Show compilation logs and debug output."
    )

    args = parser.parse_args()

    exe_path = find_executable()
    if not exe_path:
        print("[-] Error: Compiled backend executable (llama-cli or main) not found.")
        print("[-] Please run setup_backend.py and compile using build.sh or build.bat first.")
        sys.exit(1)

    print(f"[*] Using backend executable: {exe_path}")

    # Resolve model file
    model_file = args.model
    if not model_file:
        model_dir = "models"
        if os.path.exists(model_dir):
            gguf_files = [f for f in os.listdir(model_dir) if f.endswith(".gguf")]
            if len(gguf_files) == 1:
                model_file = os.path.join(model_dir, gguf_files[0])
            elif len(gguf_files) > 1:
                print("[*] Multiple models found in ./models:")
                for idx, f in enumerate(gguf_files):
                    print(f"  [{idx}] {f}")
                try:
                    choice = int(input(f"[*] Select a model [0-{len(gguf_files)-1}]: "))
                    if 0 <= choice < len(gguf_files):
                        model_file = os.path.join(model_dir, gguf_files[choice])
                except (ValueError, IndexError):
                    pass
        
    if not model_file or not os.path.isfile(model_file):
        print("[-] Error: Model file not specified or not found.")
        print("[-] Use --model <path> or download a model using download_models.py first.")
        sys.exit(1)

    print(f"[*] Loading model: {model_file}")

    # Resolve GPU layers (auto-adjusted based on model sizes or manual choice)
    gpu_layers = args.gpu_layers
    if gpu_layers == -1:
        filename = os.path.basename(model_file)
        gpu_layers = 99
        if "72B" in filename or "70B" in filename:
            print(f"[*] Large 70B/72B model detected. Using hybrid GPU execution offloading 18 layers.")
            gpu_layers = 18
        elif any(x in filename for x in ["31B", "32B", "35B", "27B"]):
            print(f"[*] Medium-large 27B-35B model detected. Using hybrid GPU execution offloading 32 layers (including Gemma 31B).")
            gpu_layers = 32
        elif "122B" in filename:
            print(f"[*] Large 122B model detected. Offloading 10 layers to GPU.")
            gpu_layers = 10
        elif "397B" in filename:
            print(f"[*] Extreme 397B model detected. Setting to CPU-only (ngl=0).")
            gpu_layers = 0
        else:
            print(f"[*] Auto-tuning GPU layers: Offloading all 99 layers for smaller model.")
    else:
        print(f"[*] Custom GPU layers specified: {gpu_layers}")

    # Construct execution command
    cmd = [
        exe_path,
        "-m", model_file,
        "-t", str(args.threads),
        "-ngl", str(gpu_layers),
        "-c", str(args.ctx_size),
        "--temp", str(args.temp),
        "-n", str(args.n_predict),
    ]

    # Add TurboQuant KV Cache quantization if enabled
    if args.turboquant:
        # In llama.cpp / forks, ctk (cache-type-k) and ctv (cache-type-v) represent KV quantization
        cmd.extend(["-ctk", "q4_0", "-ctv", "q4_0"])
        # Some forks also support direct flags like --turboquant or --rotation
        # We append standard KV cache compression to ensure compatibility across forks
        print("[+] TurboQuant KV Cache quantization enabled (K-cache: Q4_0, V-cache: Q4_0)")
    else:
        print("[*] TurboQuant KV Cache quantization disabled (K-cache: F16, V-cache: F16)")

    # Execute
    if args.prompt:
        # One-shot mode
        cmd.extend(["-p", args.prompt, "--single-turn"])
        print(f"[*] Prompt: {args.prompt}")
        print("[*] Running model...")
        try:
            subprocess.run(cmd)
        except KeyboardInterrupt:
            print("\n[!] Interrupted by user.")
    else:
        # Interactive chat/conversation mode
        # We configure chat templates typical for Gemma instruction models
        print("[*] Launching interactive chat mode. Type 'exit' or 'quit' to end.")
        cmd.extend(["-cnv", "--color"]) # Interactive conversation mode with colored speaker tags
        try:
            subprocess.run(cmd)
        except KeyboardInterrupt:
            print("\n[*] Chat session closed.")

if __name__ == "__main__":
    main()
