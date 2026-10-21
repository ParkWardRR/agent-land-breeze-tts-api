#!/usr/bin/env python3
"""Install (or uninstall) a launchd agent so the MLX API starts on login.

    python scripts/install_launchd.py           # install and load
    python scripts/install_launchd.py --remove  # unload and remove

Creates ~/Library/LaunchAgents/com.breeze-tts.mlx.plist.  The agent
restarts on crash (like Docker's `restart: unless-stopped`) and logs
to ./logs/launchd-{stdout,stderr}.log.
"""

from __future__ import annotations

import argparse
import os
import plistlib
import subprocess
import sys
from pathlib import Path

import envfile

LABEL = "com.breeze-tts.mlx"
PLIST_DIR = Path.home() / "Library" / "LaunchAgents"


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--remove", action="store_true", help="unload and remove the plist")
    args = ap.parse_args()

    plist_path = PLIST_DIR / f"{LABEL}.plist"

    if args.remove:
        subprocess.run(["launchctl", "bootout", f"gui/{os.getuid()}", str(plist_path)],
                       capture_output=True)
        if plist_path.is_file():
            plist_path.unlink()
            print(f"removed {plist_path}")
        else:
            print("plist not found; nothing to remove")
        return

    repo = envfile.REPO
    cfg = envfile.settings()
    logs = repo / "logs"
    logs.mkdir(exist_ok=True)

    env = {}
    for key in ("BREEZE_PORT", "BREEZE_BIND", "BREEZE_VOICES_DIR", "BREEZE_RESPONSES_DIR",
                "BREEZE_MODELS_DIR", "BREEZE_MLX_MODEL_DIR", "BREEZE_MLX_REPO",
                "BREEZE_MLX_COMPILE", "BREEZE_MLX_FAST_FIRST", "BREEZE_MLX_CACHE_GB",
                "BREEZE_SYNC_WAIT_SECONDS", "BREEZE_MAX_PENDING", "BREEZE_RESPONSE_TTL_SECONDS",
                "BREEZE_MIN_LEAD_SECONDS", "BREEZE_MAX_NEW_TOKENS"):
        if key in cfg:
            env[key] = cfg[key]

    python = sys.executable
    plist = {
        "Label": LABEL,
        "ProgramArguments": [python, str(repo / "runtimes" / "mlx" / "mlx_api.py")],
        "WorkingDirectory": str(repo),
        "EnvironmentVariables": env,
        "RunAtLoad": True,
        "KeepAlive": {"SuccessfulExit": False},
        "StandardOutPath": str(logs / "launchd-stdout.log"),
        "StandardErrorPath": str(logs / "launchd-stderr.log"),
        "ProcessType": "Interactive",
    }

    PLIST_DIR.mkdir(parents=True, exist_ok=True)
    subprocess.run(["launchctl", "bootout", f"gui/{os.getuid()}", str(plist_path)],
                   capture_output=True)
    with plist_path.open("wb") as f:
        plistlib.dump(plist, f)
    subprocess.run(["launchctl", "bootstrap", f"gui/{os.getuid()}", str(plist_path)], check=True)
    print(f"installed and loaded {plist_path}")
    print(f"logs: {logs / 'launchd-stdout.log'}")
    print(f"stop:   launchctl bootout gui/{os.getuid()} {plist_path}")
    print(f"remove: python scripts/install_launchd.py --remove")


if __name__ == "__main__":
    main()
