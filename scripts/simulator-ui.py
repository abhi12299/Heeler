#!/usr/bin/env python3
"""Inspect Simulator GUI tooling, or capture one explicitly selected simulator."""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
import uuid
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class Simulator:
    udid: str
    name: str
    runtime: str
    state: str
    available: bool


@dataclass(frozen=True)
class Inventory:
    selected_developer: str | None
    simctl: str | None
    applications: tuple[Path, ...]
    devices: tuple[Simulator, ...]
    errors: tuple[str, ...]


def command_output(arguments: list[str]) -> str:
    result = subprocess.run(
        arguments, text=True, capture_output=True, check=False, timeout=20,
    )
    if result.returncode:
        detail = result.stderr.strip() or result.stdout.strip()
        raise RuntimeError(f"{' '.join(arguments)} failed ({result.returncode}): {detail}")
    return result.stdout.strip()


def application_paths(simctl: str) -> tuple[Path, ...]:
    # Discover the bundle from the effective xcrun tool, including DEVELOPER_DIR.
    bundle = next((parent for parent in Path(simctl).resolve().parents
                   if parent.suffix == ".app"), None)
    if bundle is None:
        return ()
    locations = (bundle / "Contents/Applications",
                 bundle / "Contents/Developer/Applications")
    return tuple(location / name for name in ("DeviceHub.app", "Simulator.app")
                 for location in locations if (location / name).is_dir())


def discover() -> Inventory:
    selected = None
    simctl = None
    applications: tuple[Path, ...] = ()
    devices: tuple[Simulator, ...] = ()
    errors = []
    try:
        selected = command_output(["xcode-select", "-p"])
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        errors.append(str(error))
    try:
        simctl = command_output(["xcrun", "--find", "simctl"])
        applications = application_paths(simctl)
        listing = json.loads(command_output(["xcrun", "simctl", "list", "devices", "--json"]))
        devices = tuple(
            Simulator(device["udid"].upper(), device["name"], runtime,
                      device["state"], device.get("isAvailable", False))
            for runtime, entries in listing["devices"].items() for device in entries
        )
    except (OSError, RuntimeError, subprocess.SubprocessError, ValueError, KeyError, TypeError) as error:
        errors.append(str(error))
    return Inventory(selected, simctl, applications, devices, tuple(errors))


def exact_udid(value: str) -> str:
    try:
        parsed = uuid.UUID(value)
    except ValueError as error:
        raise argparse.ArgumentTypeError("Use an exact simulator UUID, not a name or alias") from error
    if str(parsed).lower() != value.lower():
        raise argparse.ArgumentTypeError("Use the complete hyphenated simulator UUID")
    return str(parsed).upper()


def show_inventory(inventory: Inventory, target: Simulator | None) -> None:
    print(f"Selected developer directory: {inventory.selected_developer or 'unavailable'}")
    if os.environ.get("DEVELOPER_DIR"):
        print(f"DEVELOPER_DIR override: {os.environ['DEVELOPER_DIR']}")
    print(f"Effective simctl: {inventory.simctl or 'unavailable'}")
    for application in inventory.applications:
        print(f"GUI application: {application}")
    if not inventory.applications:
        print("GUI application: none found in the effective Xcode bundle")
    print(f"idb: {shutil.which('idb') or 'not on PATH'}")
    print(f"idb_companion: {shutil.which('idb_companion') or 'not on PATH'}")
    print("idb paths report installation only; connection and HID support are not checked.")
    devices = (target,) if target else tuple(device for device in inventory.devices if device.available)
    print("Simulators (UUID | name | runtime identifier | state | availability):")
    for device in devices:
        print(f"  {device.udid} | {device.name} | {device.runtime} | {device.state}"
              f" | {'available' if device.available else 'unavailable'}")
    if not target:
        unavailable = sum(not device.available for device in inventory.devices)
        print(f"Unavailable simulators omitted: {unavailable}; pass --udid to inspect one.")
    for error in inventory.errors:
        print(f"ERROR: {error}", file=sys.stderr)


def open_gui(inventory: Inventory, target: Simulator) -> None:
    if not inventory.applications:
        raise RuntimeError("No Simulator or DeviceHub application found in the effective Xcode bundle")
    application = inventory.applications[0]
    command_output(["open", "-a", str(application)])
    print(f"Opened {application.name}; target selection is manual.")
    print(f"Target: {target.udid} | {target.name} | {target.runtime} | {target.state}")
    if application.name == "DeviceHub.app":
        print("DeviceHub: File > New Window, then select the matching simulator.")
        print("This menu sequence was observed on Xcode 27 (27A266a); verify labels on your version.")
    else:
        print("Simulator: File > Open Simulator, then select the matching runtime and device.")
    print("Confirm the UUID in the device details before interaction; duplicate names are ambiguous.")


def capture(target: Simulator, output: Path, overwrite: bool) -> None:
    if target.state != "Booted":
        raise RuntimeError(f"{target.udid} is {target.state}; capture requires an already Booted simulator")
    if output.suffix.lower() != ".png":
        raise RuntimeError("Use a .png output path")
    if os.path.lexists(output) and not overwrite:
        raise RuntimeError(f"Output already exists: {output}; use --overwrite to replace it")
    output.parent.mkdir(parents=True, exist_ok=True)
    # Capture first, then publish atomically. A failed capture preserves the old file.
    with tempfile.TemporaryDirectory(prefix=".simulator-capture-", dir=output.parent) as directory:
        temporary = Path(directory) / "capture.png"
        command_output(["xcrun", "simctl", "io", target.udid, "screenshot",
                        "--type=png", "--mask=black", str(temporary)])
        if not temporary.is_file() or temporary.stat().st_size == 0:
            raise RuntimeError("simctl did not produce a nonempty screenshot")
        if overwrite:
            os.replace(temporary, output)
        else:
            # link fails if another process created output after the preflight.
            os.link(temporary, output)
    print(f"Screenshot: {output} (UUID {target.udid}, mask=black)")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--udid", type=exact_udid, help="Exact UUID, required for --open or --capture")
    action = parser.add_mutually_exclusive_group()
    action.add_argument("--open", action="store_true", help="Open the discovered GUI; select target manually")
    action.add_argument("--capture", type=Path, metavar="PNG", help="Capture an already Booted simulator")
    parser.add_argument("--overwrite", action="store_true", help="Allow replacing the capture output")
    args = parser.parse_args(argv)
    if (args.open or args.capture) and not args.udid:
        parser.error("--open and --capture require --udid")
    if args.overwrite and not args.capture:
        parser.error("--overwrite requires --capture")
    inventory = discover()
    target = next((device for device in inventory.devices if device.udid == args.udid), None)
    show_inventory(inventory, target)
    if inventory.errors:
        return 2
    if args.udid and target is None:
        raise RuntimeError(f"Simulator UUID not found: {args.udid}")
    if target and (args.open or args.capture):
        if not target.available:
            raise RuntimeError(f"{target.udid} is unavailable; install its runtime before use")
        if args.open:
            open_gui(inventory, target)
        else:
            capture(target, args.capture.expanduser().absolute(), args.overwrite)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        sys.exit(2)
