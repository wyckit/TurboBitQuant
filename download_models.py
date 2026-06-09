#!/usr/bin/env python3
"""
TurboBitQuant - Gemma 4 Model Downloader
Downloads Gemma 4 GGUF models from Hugging Face for local execution.
"""
import os
import sys
import argparse

def install_and_import(package):
    import importlib
    try:
        importlib.import_module(package)
    except ImportError:
        import subprocess
        print(f"[*] Package '{package}' is not installed. Installing it now...")
        subprocess.check_call([sys.executable, "-m", "pip", "install", package])

# Ensure huggingface_hub is installed
install_and_import("huggingface_hub")
from huggingface_hub import hf_hub_download, list_repo_files

# Default repositories for Gemma 4, Qwen 2.5, Qwen 3.5, DeepSeek-R1, and Llama 3.3 models
DEFAULT_REPOS = {
    # Gemma 4
    "E2B": "unsloth/gemma-4-E2B-it-GGUF",
    "E4B": "unsloth/gemma-4-E4B-it-GGUF",
    "12B": "bartowski/gemma-4-12B-it-GGUF",
    "26B": "unsloth/gemma-4-26B-A4B-it-GGUF",
    "31B": "unsloth/gemma-4-31B-it-GGUF",
    # Qwen 2.5
    "Qwen-0.5B": "Qwen/Qwen2.5-0.5B-Instruct-GGUF",
    "Qwen-1.5B": "Qwen/Qwen2.5-1.5B-Instruct-GGUF",
    "Qwen-3B": "Qwen/Qwen2.5-3B-Instruct-GGUF",
    "Qwen-7B": "Qwen/Qwen2.5-7B-Instruct-GGUF",
    "Qwen-14B": "Qwen/Qwen2.5-14B-Instruct-GGUF",
    "Qwen-32B": "Qwen/Qwen2.5-32B-Instruct-GGUF",
    "Qwen-72B": "Qwen/Qwen2.5-72B-Instruct-GGUF",
    # Qwen 3.5
    "Qwen3.5-0.8B": "unsloth/Qwen3.5-0.8B-GGUF",
    "Qwen3.5-2B": "unsloth/Qwen3.5-2B-GGUF",
    "Qwen3.5-4B": "unsloth/Qwen3.5-4B-GGUF",
    "Qwen3.5-9B": "unsloth/Qwen3.5-9B-GGUF",
    "Qwen3.5-27B": "unsloth/Qwen3.5-27B-GGUF",
    "Qwen3.5-35B": "unsloth/Qwen3.5-35B-GGUF",
    # DeepSeek R1 Distilled Models (Reasoning / Chain-of-Thought)
    "R1-Qwen-1.5B": "unsloth/DeepSeek-R1-Distill-Qwen-1.5B-GGUF",
    "R1-Llama-8B": "unsloth/DeepSeek-R1-Distill-Llama-8B-GGUF",
    "R1-Qwen-7B": "unsloth/DeepSeek-R1-Distill-Qwen-7B-GGUF",
    "R1-Qwen-14B": "unsloth/DeepSeek-R1-Distill-Qwen-14B-GGUF",
    "R1-Qwen-32B": "unsloth/DeepSeek-R1-Distill-Qwen-32B-GGUF",
    "R1-Llama-70B": "unsloth/DeepSeek-R1-Distill-Llama-70B-GGUF",
    # Meta Llama 3.3
    "Llama-3.3-70B": "unsloth/Llama-3.3-70B-Instruct-GGUF"
}

# Common quantization formats
COMMON_QUANTS = ["Q4_K_M", "Q8_0", "Q3_K_L", "Q5_K_M", "Q6_K", "IQ4_XS"]

def main():
    parser = argparse.ArgumentParser(description="Download GGUF models from Hugging Face.")
    parser.add_argument(
        "--model", 
        type=str, 
        choices=[
            "E2B", "E4B", "12B", "26B", "31B",
            "Qwen-0.5B", "Qwen-1.5B", "Qwen-3B", "Qwen-7B", "Qwen-14B", "Qwen-32B", "Qwen-72B",
            "Qwen3.5-0.8B", "Qwen3.5-2B", "Qwen3.5-4B", "Qwen3.5-9B", "Qwen3.5-27B", "Qwen3.5-35B",
            "R1-Qwen-1.5B", "R1-Llama-8B", "R1-Qwen-7B", "R1-Qwen-14B", "R1-Qwen-32B", "R1-Llama-70B",
            "Llama-3.3-70B"
        ], 
        default="12B",
        help="Model name/size to download (default: 12B)"
    )
    parser.add_argument(
        "--quant", 
        type=str, 
        default="Q4_K_M",
        help="Quantization format to download (e.g. Q4_K_M, Q8_0, or Ternary/1.58bit if available). Default: Q4_K_M"
    )
    parser.add_argument(
        "--repo", 
        type=str, 
        default=None,
        help="Override default Hugging Face repository (e.g. bartowski/gemma-4-12B-it-GGUF)"
    )
    parser.add_argument(
        "--output-dir", 
        type=str, 
        default="models",
        help="Directory to save the downloaded model (default: ./models)"
    )
    parser.add_argument(
        "--token", 
        type=str, 
        default=os.environ.get("HF_TOKEN"),
        help="Hugging Face API Token. Can also be set via the HF_TOKEN environment variable."
    )
    parser.add_argument(
        "--list-files", 
        action="store_true",
        help="List files in the Hugging Face repository without downloading."
    )

    args = parser.parse_args()

    repo_id = args.repo if args.repo else DEFAULT_REPOS.get(args.model)
    if not repo_id:
        print(f"[-] Unknown model identifier: {args.model}")
        sys.exit(1)

    print(f"[*] Target Repository: {repo_id}")
    
    # Try to list repo files to verify access
    try:
        files = list_repo_files(repo_id=repo_id, token=args.token)
    except Exception as e:
        print(f"[-] Error listing repository files: {e}")
        print("[-] If this is a gated model, please provide your HF_TOKEN via --token or the HF_TOKEN environment variable.")
        print("[-] Make sure you have accepted the model terms on Hugging Face.")
        sys.exit(1)

    if args.list_files:
        print(f"[*] Files available in {repo_id}:")
        for f in files:
            if f.endswith(".gguf"):
                print(f"  - {f}")
        sys.exit(0)

    # Filter GGUF files matching the desired quantization
    gguf_files = [f for f in files if f.endswith(".gguf")]
    
    # Try to find a file matching the specific quantization (case insensitive)
    target_file = None
    quant_lower = args.quant.lower()
    for f in gguf_files:
        if quant_lower in f.lower():
            target_file = f
            break
            
    if not target_file:
        # If not found, try to match partially or fallback
        print(f"[!] Exact quantization '{args.quant}' not found in {repo_id}.")
        print("[*] Available GGUF files:")
        for idx, f in enumerate(gguf_files):
            print(f"  [{idx}] {f}")
        
        if not gguf_files:
            print("[-] No GGUF files found in this repository.")
            sys.exit(1)
            
        try:
            choice = input(f"[*] Select a file to download [0-{len(gguf_files)-1}] (or press Enter to download index 0): ").strip()
            if choice == "":
                target_file = gguf_files[0]
            else:
                idx = int(choice)
                if 0 <= idx < len(gguf_files):
                    target_file = gguf_files[idx]
                else:
                    print("[-] Invalid selection.")
                    sys.exit(1)
        except (ValueError, IndexError, KeyboardInterrupt):
            print("\n[-] Download cancelled.")
            sys.exit(1)

    os.makedirs(args.output_dir, exist_ok=True)
    destination = os.path.join(args.output_dir, target_file)
    
    print(f"[*] Downloading file: {target_file}")
    print(f"[*] Destination: {destination}")
    print("[*] Starting download (this may take some time depending on file size)...")
    
    try:
        filepath = hf_hub_download(
            repo_id=repo_id,
            filename=target_file,
            local_dir=args.output_dir,
            local_dir_use_symlinks=False,
            token=args.token
        )
        print(f"[+] Download complete! File saved to: {filepath}")
    except Exception as e:
        print(f"[-] Error downloading file: {e}")
        sys.exit(1)

if __name__ == "__main__":
    main()
