#!/usr/bin/env python3
"""Print an available iPhone simulator UDID from the newest installed iOS runtime."""

from __future__ import annotations

import json
import re
import subprocess
import sys


def runtime_version(identifier: str) -> tuple[int, ...]:
    match = re.search(r"iOS-(\d+(?:-\d+)*)$", identifier)
    if match is None:
        return ()
    return tuple(int(component) for component in match.group(1).split("-"))


def main() -> int:
    result = subprocess.run(
        ["xcrun", "simctl", "list", "devices", "available", "--json"],
        check=True,
        capture_output=True,
        text=True,
    )
    payload = json.loads(result.stdout)
    candidates: list[tuple[tuple[int, ...], str, str]] = []
    for runtime, devices in payload.get("devices", {}).items():
        version = runtime_version(runtime)
        if not version:
            continue
        for device in devices:
            name = device.get("name", "")
            udid = device.get("udid", "")
            if device.get("isAvailable", True) and name.startswith("iPhone") and udid:
                candidates.append((version, name, udid))
    if not candidates:
        print("no available iPhone simulator is installed", file=sys.stderr)
        return 1
    newest_version = max(candidate[0] for candidate in candidates)
    newest_devices = sorted(candidate for candidate in candidates if candidate[0] == newest_version)
    print(newest_devices[0][2])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
