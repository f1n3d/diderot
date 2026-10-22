#!/usr/bin/env python3
"""Prints the UDID of the available iOS simulator named argv[1] (Tools/run-sim.sh, Tools/run-uitests.sh)."""
import json, subprocess, sys
devices = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "-j"]))["devices"]
name = sys.argv[1]
matches = [(runtime, d) for runtime, devs in devices.items() if "iOS" in runtime for d in devs if d["name"] == name]
if not matches:
    sys.exit(f"Simulator {name!r} not found")
# Prefer the newest iOS runtime (e.g. iOS-27-0 over iOS-26-2).
def version(runtime):
    return [int(p) for p in runtime.rsplit("iOS-", 1)[-1].split("-") if p.isdigit()]
print(sorted(matches, key=lambda m: version(m[0]), reverse=True)[0][1]["udid"])
