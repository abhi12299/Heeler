#!/usr/bin/env python3
"""Refresh the free Apple ID build before its 7-day profile lapses.

A plain `make free-install` reuses the cached provisioning profile until it
expires, and iOS then drops the developer trust. Deleting the cached profile
first makes Xcode issue a new one with a fresh 7 days.

  refresh-free-profile.py run              refresh now
  refresh-free-profile.py check            ask first; what the LaunchAgent runs
  refresh-free-profile.py install-agent    check at login and every 12 hours
  refresh-free-profile.py uninstall-agent
"""

from __future__ import annotations

import argparse
import datetime
import os
import pathlib
import plistlib
import subprocess
import sys

REPO = pathlib.Path(__file__).resolve().parents[2]
BUNDLE_ID_FILE = REPO / "build/free/bundle-id"
PROFILE_DIR = pathlib.Path.home() / "Library/Developer/Xcode/UserData/Provisioning Profiles"
LOG = pathlib.Path.home() / "Library/Logs/heeler-free-refresh.log"
AGENT_LABEL = "dev.heeler.free-refresh"
AGENT_PLIST = pathlib.Path.home() / f"Library/LaunchAgents/{AGENT_LABEL}.plist"
CHECK_INTERVAL_SECONDS = 12 * 60 * 60
# The dialog must be gone before launchd's next check is due.
DIALOG_TIMEOUT_SECONDS = CHECK_INTERVAL_SECONDS - 60 * 60
# launchd starts agents with a bare PATH; the build needs xcodegen and a
# python3 that has PyYAML.
AGENT_PATH_FALLBACK = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"


def log(message: str) -> None:
    stamp = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    LOG.parent.mkdir(parents=True, exist_ok=True)
    with LOG.open("a") as handle:
        handle.write(f"{stamp} {message}\n")
    print(message)


def bundle_id() -> str | None:
    if not BUNDLE_ID_FILE.exists():
        return None
    return BUNDLE_ID_FILE.read_text().strip() or None


def cached_profiles(bundle: str) -> list[tuple[pathlib.Path, datetime.datetime]]:
    """Cached profiles for the free bundle id, with their UTC expiry."""
    found = []
    for path in sorted(PROFILE_DIR.glob("*.mobileprovision")):
        decoded = subprocess.run(
            ["security", "cms", "-D", "-i", str(path)], capture_output=True, check=False
        )
        if decoded.returncode:
            continue
        profile = plistlib.loads(decoded.stdout)
        identifier = profile.get("Entitlements", {}).get("application-identifier", "")
        if identifier.endswith(f".{bundle}"):
            expiry = profile["ExpirationDate"].replace(tzinfo=datetime.timezone.utc)
            found.append((path, expiry))
    return found


def days_left(bundle: str) -> float:
    profiles = cached_profiles(bundle)
    if not profiles:
        return 0.0
    remaining = max(expiry for _, expiry in profiles) - datetime.datetime.now(datetime.timezone.utc)
    return remaining.total_seconds() / 86400


def reachable_iphone() -> str | None:
    found = subprocess.run(
        [sys.executable, str(REPO / "scripts/find-ios-device.py"), "iPhone"],
        capture_output=True, text=True, check=False,
    )
    udid = found.stdout.strip()
    if found.returncode or not udid:
        return None
    probe = subprocess.run(
        ["xcrun", "devicectl", "device", "info", "lockState", "--device", udid, "--timeout", "20"],
        capture_output=True, check=False,
    )
    return None if probe.returncode else udid


def applescript_string(text: str) -> str:
    return '"' + text.replace("\\", "\\\\").replace('"', '\\"') + '"'


def notify(message: str) -> None:
    script = f"display notification {applescript_string(message)} with title \"Heeler free build\""
    subprocess.run(["osascript", "-e", script], capture_output=True, check=False)


def ask(message: str, timeout: int) -> bool:
    # A banner cannot carry buttons without a third-party notifier, so the
    # question is a dialog. "Not now" and the timeout both leave it for the
    # next check.
    script = (
        f"display dialog {applescript_string(message)} with title \"Heeler free build\" "
        'buttons {"Not now", "Allow"} default button "Allow" cancel button "Not now" '
        f"giving up after {timeout}"
    )
    answer = subprocess.run(["osascript", "-e", script], capture_output=True, text=True, check=False)
    return answer.returncode == 0 and "button returned:Allow" in answer.stdout


def refresh(bundle: str, udid: str) -> bool:
    # Superseded profiles are deleted, not kept: Xcode only issues a new one
    # when no valid profile for the bundle id is cached.
    for path, _ in cached_profiles(bundle):
        path.unlink()
        log(f"removed cached profile {path.name}")
    with LOG.open("a") as handle:
        build = subprocess.run(
            ["make", "free-install", f"DEVICE={udid}"],
            cwd=REPO, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, check=False,
        )
        handle.write(build.stdout[-20000:])
    if build.returncode:
        log(f"make free-install failed with exit {build.returncode}")
        notify(f"Refresh failed. See {LOG}")
        return False
    left = days_left(bundle)
    # make echoes the recipe, refusal text included, so match devicectl's success line.
    if "Launched application" not in build.stdout:
        log(f"installed, launch refused; {left:.1f} days left")
        notify(f"Installed with {left:.1f} days left, but the launch was refused. Unlock the iPhone and open Heeler.")
    else:
        log(f"refreshed; {left:.1f} days left")
        notify(f"Refreshed and relaunched. {left:.1f} days left.")
    return True


def command_run(_: argparse.Namespace) -> int:
    bundle = bundle_id()
    if bundle is None:
        log("no free build yet; run `make free-install` first")
        return 1
    udid = reachable_iphone()
    if udid is None:
        log("no reachable iPhone")
        return 1
    return 0 if refresh(bundle, udid) else 1


def command_check(arguments: argparse.Namespace) -> int:
    bundle = bundle_id()
    if bundle is None:
        log("check: no free build yet, nothing to refresh")
        return 0
    left = days_left(bundle)
    if left >= arguments.below_days:
        log(f"check: {left:.1f} days left, not asking")
        return 0
    udid = reachable_iphone()
    if udid is None:
        log(f"check: {left:.1f} days left, iPhone not reachable")
        if left < arguments.warn_days:
            notify(f"{left:.1f} days left and the iPhone is not reachable. Connect it to refresh.")
        return 0
    state = f"expires in {left:.1f} days" if left > 0 else "has expired"
    if not ask(f"The Heeler free build {state}. Rebuild and reinstall it on the iPhone now?", arguments.dialog_timeout):
        log(f"check: {left:.1f} days left, declined")
        return 0
    return 0 if refresh(bundle, udid) else 1


def command_install_agent(_: argparse.Namespace) -> int:
    python_dir = str(pathlib.Path(sys.executable).parent)
    plist = {
        "Label": AGENT_LABEL,
        # Launch the script itself: macOS labels a background item by the signer
        # of its program, and naming python3 here shows Python's signer instead.
        "ProgramArguments": [str(pathlib.Path(__file__).resolve()), "check"],
        "RunAtLoad": True,
        "StartInterval": CHECK_INTERVAL_SECONDS,
        "ProcessType": "Background",
        "EnvironmentVariables": {"PATH": f"{python_dir}:{AGENT_PATH_FALLBACK}"},
        "StandardOutPath": "/dev/null",
        "StandardErrorPath": str(LOG),
    }
    target = f"gui/{os.getuid()}"
    subprocess.run(["launchctl", "bootout", f"{target}/{AGENT_LABEL}"], capture_output=True, check=False)
    AGENT_PLIST.write_bytes(plistlib.dumps(plist))
    loaded = subprocess.run(["launchctl", "bootstrap", target, str(AGENT_PLIST)], check=False)
    if loaded.returncode == 0:
        print(f"Installed {AGENT_PLIST}; log at {LOG}")
    return loaded.returncode


def command_uninstall_agent(_: argparse.Namespace) -> int:
    subprocess.run(
        ["launchctl", "bootout", f"gui/{os.getuid()}/{AGENT_LABEL}"], capture_output=True, check=False
    )
    AGENT_PLIST.unlink(missing_ok=True)
    print(f"Removed {AGENT_PLIST}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("run").set_defaults(handler=command_run)
    check = commands.add_parser("check")
    check.add_argument("--below-days", type=float, default=5.0, help="ask once fewer days than this remain")
    check.add_argument("--warn-days", type=float, default=2.0, help="warn about an unreachable iPhone below this")
    check.add_argument("--dialog-timeout", type=int, default=DIALOG_TIMEOUT_SECONDS, help=argparse.SUPPRESS)
    check.set_defaults(handler=command_check)
    commands.add_parser("install-agent").set_defaults(handler=command_install_agent)
    commands.add_parser("uninstall-agent").set_defaults(handler=command_uninstall_agent)
    arguments = parser.parse_args()
    return arguments.handler(arguments)


if __name__ == "__main__":
    sys.exit(main())
