#!/usr/bin/env python3
"""Detect Apple Silicon hardware and write matching MLX settings into .env.

    python scripts/configure_macos.py                  # detect, print, write .env
    python scripts/configure_macos.py --model int8     # choose model explicitly
    python scripts/configure_macos.py --dry-run        # print without writing

Sets COMPOSE_PROFILES=mlx, BREEZE_MLX_REPO and MLX tuning variables.
"""

from __future__ import annotations

import argparse
import platform
import re
import subprocess
import sys

import envfile

MLX_MODELS = {
    "gust": {
        "repo": "Shoof/Gust-MLX",
        "dir": "mlx-gust",
        "min_gb": 16,
        "desc": "bf16 backbone + int8 depth decoder (7.28 GB, RTF ~0.62, ~9 GB memory)",
    },
    "int8": {
        "repo": "rishikksh20/Breeze-TTS-2-mlx",
        "dir": "mlx-int8",
        "min_gb": 8,
        "desc": "INT8 quantized (3.72 GB, RTF ~0.53, ~4 GB memory)",
    },
}


def _run(cmd: list[str]) -> str:
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=10).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return ""


def chip_info() -> dict:
    """Detect Apple Silicon chip model and capabilities."""
    info: dict = {
        "arch": platform.machine(),
        "chip": "unknown",
        "gpu_cores": 0,
        "neural_engine_cores": 0,
        "memory_gb": 0,
        "macos_version": platform.mac_ver()[0],
    }

    if info["arch"] != "arm64":
        return info

    chip_raw = _run(["sysctl", "-n", "machdep.cpu.brand_string"])
    if chip_raw:
        info["chip"] = chip_raw

    sp = _run(["system_profiler", "SPHardwareDataType"])
    for line in sp.splitlines():
        line = line.strip()
        if "Chip:" in line or "Chip Name:" in line:
            info["chip"] = line.split(":", 1)[1].strip()
        elif "Memory:" in line or "Total Number of Cores" in line:
            m = re.search(r"(\d+)\s*GB", line)
            if m:
                info["memory_gb"] = int(m.group(1))
        elif "Number of Cores" in line and "GPU" not in line:
            pass

    sp_display = _run(["system_profiler", "SPDisplaysDataType"])
    for line in sp_display.splitlines():
        line = line.strip()
        if "Total Number of Cores" in line:
            m = re.search(r"(\d+)", line)
            if m:
                info["gpu_cores"] = int(m.group(1))

    mem_bytes = _run(["sysctl", "-n", "hw.memsize"])
    if mem_bytes and mem_bytes.isdigit():
        info["memory_gb"] = int(mem_bytes) // (1024 ** 3)

    ane = _run(["ioreg", "-r", "-c", "AppleARMIODevice", "-n", "ane0"])
    if "ane0" in ane.lower():
        m = re.search(r"neural-engine-count.*?(\d+)", ane, re.DOTALL)
        info["neural_engine_cores"] = int(m.group(1)) if m else 16

    return info


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--model", choices=["gust", "int8", "auto"], default="auto",
                    help="MLX model variant (default: auto-detect by memory)")
    ap.add_argument("--dry-run", action="store_true", help="print settings without writing .env")
    args = ap.parse_args()

    if platform.system() != "Darwin":
        sys.exit("This script is for macOS only. Use scripts/configure.py for Linux/NVIDIA.")

    info = chip_info()
    if info["arch"] != "arm64":
        sys.exit("Apple Silicon (ARM64) required. Intel Macs are not supported.")

    print(f"Chip:    {info['chip']}")
    print(f"Memory:  {info['memory_gb']} GB unified")
    print(f"GPU:     {info['gpu_cores']} cores" if info["gpu_cores"] else "GPU:     (detection pending)")
    print(f"ANE:     {info['neural_engine_cores']} cores" if info["neural_engine_cores"] else "ANE:     present")
    print(f"macOS:   {info['macos_version']}")

    if args.model == "auto":
        model = "gust" if info["memory_gb"] >= 16 else "int8"
        print(f"\nauto-detected model: {model} (based on {info['memory_gb']} GB memory)")
    else:
        model = args.model

    model_info = MLX_MODELS[model]
    if info["memory_gb"] < model_info["min_gb"]:
        print(f"warning: {model} needs at least {model_info['min_gb']} GB; you have {info['memory_gb']} GB.")

    print(f"model:   {model_info['desc']}")

    changes = {
        "COMPOSE_PROFILES": "mlx",
        "BREEZE_MLX_REPO": model_info["repo"],
        "BREEZE_MLX_MODEL_DIR": model_info["dir"],
        "BREEZE_MLX_COMPILE": "1",
        "BREEZE_MLX_FAST_FIRST": "6",
        "BREEZE_MLX_CACHE_GB": "1",
    }

    print("\nsettings:")
    for k, v in changes.items():
        print(f"  {k}={v}")
    if args.dry_run:
        print("\n(dry run: .env not changed)")
        return
    envfile.update(changes)
    print(f"\nwrote {envfile.ENV}. Next: python scripts/download_models.py && ./runtimes/mlx/run.sh")


if __name__ == "__main__":
    main()
