#!/usr/bin/env python3
"""
TurboBitQuant - Backend Setup Script
Clones the specialized llama.cpp fork with Ternary (BitNet) and TurboQuant support.
"""
import os
import sys
import shutil
import subprocess

TARGET_REPO = "https://github.com/LyndonBlack/llama.cpp-Ternary-1.58Bit-and-TurboQuant.git"
FALLBACK_REPO = "https://github.com/TheTom/llama-cpp-turboquant.git"
TARGET_DIR = "llama.cpp"

def run_command(cmd, cwd=None):
    print(f"[*] Running: {' '.join(cmd)}")
    try:
        subprocess.check_call(cmd, cwd=cwd)
        return True
    except subprocess.CalledProcessError as e:
        print(f"[-] Command failed with exit code {e.returncode}: {' '.join(cmd)}")
        return False

def main():
    print("[*] Setting up TurboBitQuant C++ Backend...")

    # Check for git
    if not shutil.which("git"):
        print("[-] Error: 'git' is not installed or not in the PATH. Git is required to set up the backend.")
        sys.exit(1)

    # Clone repository
    if os.path.exists(TARGET_DIR):
        print(f"[!] Target directory '{TARGET_DIR}' already exists.")
        choice = input("[*] Delete existing directory and re-clone? (y/n) [n]: ").strip().lower()
        if choice == 'y':
            print(f"[*] Deleting '{TARGET_DIR}'...")
            shutil.rmtree(TARGET_DIR)
        else:
            print("[*] Skipping clone, checking submodules...")
            run_command(["git", "submodule", "update", "--init", "--recursive"], cwd=TARGET_DIR)
            print("[+] Backend setup complete!")
            sys.exit(0)

    # Clone primary repo
    success = run_command(["git", "clone", "--depth", "1", TARGET_REPO, TARGET_DIR])
    
    # Fallback to secondary repo if primary fails
    if not success:
        print("[!] Primary repository cloning failed. Trying fallback repository...")
        success = run_command(["git", "clone", "--depth", "1", FALLBACK_REPO, TARGET_DIR])
        
    if not success:
        print("[-] Error: Failed to clone both primary and fallback repositories.")
        sys.exit(1)

    # Update submodules
    print("[*] Initializing git submodules...")
    submodule_success = run_command(["git", "submodule", "update", "--init", "--recursive"], cwd=TARGET_DIR)
    if not submodule_success:
        print("[!] Submodule update failed, but proceeding since compile might succeed without them depending on build configuration.")

    print(f"[+] Backend cloned successfully to: {os.path.abspath(TARGET_DIR)}")
    print("[*] Next step: Run build.sh (macOS/Linux) or build.bat (Windows) to compile the C++ binaries.")

if __name__ == "__main__":
    main()
