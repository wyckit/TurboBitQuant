#!/usr/bin/env python3
"""
TurboBitQuant - Model Benchmark Suite
Runs specialized intelligence and performance tests across all downloaded models
and generates a comparison report.
"""
import os
import re
import sys
import json
import time
import subprocess
import multiprocessing

# Core test cases to run on each model
BENCHMARKS = [
    {
        "id": "reasoning_math",
        "name": "Logical & Mathematical Reasoning",
        "prompt": "Solve this puzzle step-by-step: A bat and a ball cost $1.10 in total. The bat costs $1.00 more than the ball. How much does the ball cost? Show your calculations."
    },
    {
        "id": "coding_prime",
        "name": "Code Generation & Optimization",
        "prompt": "Write a highly optimized Python function to check if a number is prime. Explain the time complexity."
    },
    {
        "id": "general_knowledge",
        "name": "Concept Summarization",
        "prompt": "Summarize the theory of general relativity in exactly three clear, simple bullet points."
    }
]

def find_executable():
    """Locates the compiled backend executables in bin/ or path."""
    ext = ".exe" if os.name == "nt" else ""
    candidates = [
        os.path.join("bin", f"llama-cli{ext}"),
        os.path.join("bin", f"main{ext}"),
    ]
    for c in candidates:
        if os.path.isfile(c):
            return c
    return None

def parse_timings(stderr_text):
    """
    Parses llama-cli stderr output to extract execution speed and load times.
    Example lines:
    llama_print_timings:        load time =     230.12 ms
    llama_print_timings: prompt eval time =     123.45 ms /    32 tokens (    3.86 ms per token,   259.21 t/s)
    llama_print_timings:        eval time =    1245.50 ms /    80 runs   (   15.57 ms per token,    64.23 t/s)
    """
    timings = {
        "load_time_ms": 0.0,
        "prompt_speed_ts": 0.0,
        "gen_speed_ts": 0.0,
        "prompt_tokens": 0,
        "gen_tokens": 0
    }
    
    # Extract load time
    load_match = re.search(r"load time\s*=\s*([\d.]+)\s*ms", stderr_text)
    if load_match:
        timings["load_time_ms"] = float(load_match.group(1))
        
    # Extract prompt eval time and speed
    prompt_match = re.search(r"prompt eval time\s*=\s*([\d.]+)\s*ms\s*/\s*(\d+)\s*tokens.*?([\d.]+)\s*t/s", stderr_text)
    if prompt_match:
        timings["prompt_tokens"] = int(prompt_match.group(2))
        timings["prompt_speed_ts"] = float(prompt_match.group(3))
        
    # Extract generation eval time and speed
    eval_match = re.search(r"eval time\s*=\s*([\d.]+)\s*ms\s*/\s*(\d+)\s*runs.*?([\d.]+)\s*t/s", stderr_text)
    if eval_match:
        timings["gen_tokens"] = int(eval_match.group(2))
        timings["gen_speed_ts"] = float(eval_match.group(3))
        
    return timings

def run_single_benchmark(exe_path, model_path, benchmark, threads, gpu_layers):
    """Runs a single prompt through the model and captures outputs + timings."""
    cmd = [
        exe_path,
        "-m", model_path,
        "-t", str(threads),
        "-ngl", str(gpu_layers),
        "-c", "2048",
        "-n", "512",
        "--temp", "0.0", # Deterministic for benchmarking
        "-ctk", "q4_0",  # TurboQuant key cache
        "-ctv", "q4_0",  # TurboQuant value cache
        "-p", benchmark["prompt"],
        "--single-turn"  # Prevent REPL hang
    ]
    
    print(f"    [*] Running test: {benchmark['name']}...")
    start_time = time.time()
    
    # Run and capture output
    result = subprocess.run(cmd, stdin=subprocess.DEVNULL, capture_output=True, text=True)
    elapsed = time.time() - start_time
    
    stdout = result.stdout
    stderr = result.stderr
    
    timings = parse_timings(stderr)
    
    # If timings failed to parse via standard printings, use fallbacks
    if timings["prompt_speed_ts"] == 0.0 and timings["gen_speed_ts"] == 0.0:
        # Check if we can parse the inline statistics [ Prompt: X t/s | Generation: Y t/s ]
        inline_match = re.search(r"\[\s*Prompt:\s*([\d.]+)\s*t/s\s*\|\s*Generation:\s*([\d.]+)\s*t/s\s*\]", stdout)
        if inline_match:
            timings["prompt_speed_ts"] = float(inline_match.group(1))
            timings["gen_speed_ts"] = float(inline_match.group(2))
            
    # Clean up output response
    response = stdout.strip()
    # Strip the prompt from the beginning if the backend prints it
    if response.startswith(benchmark["prompt"]):
        response = response[len(benchmark["prompt"]):].strip()
        
    return {
        "benchmark_id": benchmark["id"],
        "benchmark_name": benchmark["name"],
        "response": response,
        "elapsed_seconds": elapsed,
        "timings": timings
    }

def main():
    print("=" * 60)
    print("        TurboBitQuant - Cross-Model Benchmark Suite")
    print("=" * 60)
    
    exe_path = find_executable()
    if not exe_path:
        print("[-] Error: Compiled backend executable (llama-cli) not found in ./bin/")
        sys.exit(1)
        
    model_dir = "models"
    if not os.path.exists(model_dir):
        print(f"[-] Error: Models directory './{model_dir}' does not exist.")
        sys.exit(1)
        
    gguf_files = sorted([f for f in os.listdir(model_dir) if f.endswith(".gguf")])
    if not gguf_files:
        print("[-] Error: No .gguf models found in ./models/. Please download models first.")
        sys.exit(1)
        
    print(f"[*] Found {len(gguf_files)} models to benchmark:")
    for f in gguf_files:
        print(f"  - {f}")
        
    threads = max(1, multiprocessing.cpu_count() - 2)
    gpu_layers = 99  # Max GPU offload
    
    results = {}
    
    for filename in gguf_files:
        model_name = filename.replace(".gguf", "")
        model_path = os.path.join(model_dir, filename)
        
        # Prevent GPU OOM for large models by offloading a safe subset of layers to GPU (hybrid inference)
        current_gpu_layers = gpu_layers
        if "72B" in filename or "70B" in filename:
            print(f"[*] Detected 70B/72B model {filename}. Using hybrid GPU execution offloading 18 layers.")
            current_gpu_layers = 18
        elif any(x in filename for x in ["31B", "32B", "35B", "27B"]):
            print(f"[*] Detected 27B-35B model {filename}. Using hybrid GPU execution offloading 32 layers.")
            current_gpu_layers = 32
        elif "122B" in filename:
            print(f"[*] Detected 122B model {filename}. Offloading 10 layers to GPU.")
            current_gpu_layers = 10
        elif "397B" in filename:
            print(f"[*] Extreme 397B model {filename}. Forcing CPU-only execution (ngl=0).")
            current_gpu_layers = 0
            
        print(f"\n[*] Benchmarking model: {model_name}...")
        results[model_name] = []
        
        for b in BENCHMARKS:
            try:
                res = run_single_benchmark(exe_path, model_path, b, threads, current_gpu_layers)
                results[model_name].append(res)
                print(f"      [+] Completed in {res['elapsed_seconds']:.2f}s (Prompt: {res['timings']['prompt_speed_ts']:.1f} t/s | Gen: {res['timings']['gen_speed_ts']:.1f} t/s)")
            except Exception as e:
                print(f"      [-] Failed running test {b['name']}: {e}")
                
    # Generate report
    report_path = "benchmark_results.md"
    print(f"\n[*] Generating benchmark report: {report_path}...")
    
    with open(report_path, "w") as f:
        f.write("# TurboBitQuant Benchmark Evaluation Report\n\n")
        f.write(f"Generated on: {time.strftime('%Y-%m-%d %H:%M:%S')}\n")
        f.write(f"System Configuration: {multiprocessing.cpu_count()} CPU Cores (using {threads} threads), Apple Metal GPU acceleration enabled.\n\n")
        
        f.write("## 📊 Speed & Efficiency Comparison\n\n")
        f.write("| Model Name | Model Load Time | Prompt Eval Speed | Generation Speed | Avg. Latency |\n")
        f.write("| :--- | :--- | :--- | :--- | :--- |\n")
        
        for model, tests in results.items():
            if not tests:
                continue
            avg_load = sum(t["timings"]["load_time_ms"] for t in tests) / len(tests) / 1000.0  # seconds
            avg_prompt = sum(t["timings"]["prompt_speed_ts"] for t in tests) / len(tests)
            avg_gen = sum(t["timings"]["gen_speed_ts"] for t in tests) / len(tests)
            avg_elapsed = sum(t["elapsed_seconds"] for t in tests) / len(tests)
            
            f.write(f"| **{model}** | {avg_load:.2f}s | {avg_prompt:.1f} t/s | {avg_gen:.1f} t/s | {avg_elapsed:.2f}s |\n")
            
        f.write("\n---\n\n")
        f.write("## 🧠 Specialized Intelligence Test Responses\n\n")
        
        for b in BENCHMARKS:
            f.write(f"### 📍 Task: {b['name']}\n")
            f.write(f"**Prompt**: *\"{b['prompt']}\"*\n\n")
            
            for model, tests in results.items():
                # Find matching test
                test_res = next((t for t in tests if t["benchmark_id"] == b["id"]), None)
                if test_res:
                    f.write(f"#### 🤖 Model: {model}\n")
                    f.write(f"- **Speed**: Prompt {test_res['timings']['prompt_speed_ts']:.1f} t/s | Generation {test_res['timings']['gen_speed_ts']:.1f} t/s\n")
                    f.write("- **Response**:\n")
                    # Format thinking blocks if any
                    resp = test_res["response"]
                    if "[Start thinking]" in resp:
                        # Wrap thinking block in an alert or blockquote
                        resp = resp.replace("[Start thinking]", "> [!NOTE]\n> **Thinking Process:**\n>")
                        resp = resp.replace("[End thinking]", "\n")
                    
                    # Indent response lines for markdown rendering
                    formatted_lines = []
                    for line in resp.split("\n"):
                        formatted_lines.append(line)
                    f.write("\n" + "\n".join(formatted_lines) + "\n\n")
            f.write("\n---\n\n")
            
    print(f"[+] Benchmark execution completed! Report saved to: {os.path.abspath(report_path)}")
    print("[*] You can view the report to see model speed and response comparisons.")

if __name__ == "__main__":
    main()
