#!/usr/bin/env python3
"""Select an exact installed runtime and create a requested device if necessary."""
import argparse, json, subprocess

def select_runtime(runtimes, version):
    return next((r["identifier"] for r in runtimes if r.get("version") == version and r.get("isAvailable") and r.get("identifier", "").startswith("com.apple.CoreSimulator.SimRuntime.iOS-")), None)

def select_device(devices, runtime, family, name=None):
    candidates = [d for d in devices.get(runtime, []) if d.get("isAvailable") and family in d["name"]]
    if name:
        candidates = [d for d in candidates if d["name"] == name]
    return candidates[0]["udid"] if candidates else None

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--runtime", required=True)
    parser.add_argument("--family", choices=["iPhone", "iPad"], required=True)
    parser.add_argument("--name")
    args = parser.parse_args()
    runtimes = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "runtimes", "--json"]))["runtimes"]
    runtime = select_runtime(runtimes, args.runtime)
    if runtime is None:
        raise SystemExit(f"Required iOS {args.runtime} runtime is not installed; refusing to silently use another version.")
    devices = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "--json"]))["devices"]
    device = select_device(devices, runtime, args.family, args.name)
    if not device:
        types = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devicetypes", "--json"]))["devicetypes"]
        wanted = next((t for t in types if t["name"] == args.name), None)
        if not wanted:
            raise SystemExit(f"No available {args.name or args.family} on iOS {args.runtime}")
        device = subprocess.check_output(["xcrun", "simctl", "create", args.name, wanted["identifier"], runtime], text=True).strip()
    print(device)

if __name__ == "__main__": main()
