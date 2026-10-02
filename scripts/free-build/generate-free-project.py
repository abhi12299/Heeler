#!/usr/bin/env python3
"""Generate HeelerFree.xcodeproj: Heeler signed by a free (personal) Apple ID team.

A free provisioning team cannot sign the Push Notifications or App Groups
capabilities, and every extension spends one of its ten App IDs per week. So
this derives a trimmed spec from the committed project.yml instead of forking
it, and leaves the upstream project, entitlements, and Info.plist untouched:

- the app keeps its sources, packages, and build settings;
- the Notification Service and Widgets extensions are dropped (no push to
  decrypt, and no app group to share Notification Keys through), as is the
  unit-test bundle, which a device install never runs;
- entitlements are empty (no aps-environment, no application-groups), and
  Live Activities are not declared, since no widget extension renders them;
- the bundle id moves to one the free team can register, and the team is the
  personal team.

Without the app group the app degrades on its own: the Notification Key
mirror's container URL is nil, Keychain reads in the shared access group fail
into "no records", and known hosts already live in standard UserDefaults.

Usage: generate-free-project.py [--team TEAM_ID] [--bundle-id ID]
The team defaults to the one free provisioning team Xcode knows about.
"""

import argparse
import pathlib
import plistlib
import subprocess
import sys

import yaml

ROOT = pathlib.Path(__file__).resolve().parents[2]
OUT = ROOT / "build" / "free"
DROPPED_TARGETS = {"HeelerNotificationService", "HeelerWidgets", "HeelerTests"}


def free_teams():
    """Personal teams registered with Xcode on this Mac, as (id, name)."""
    try:
        raw = subprocess.run(
            ["defaults", "export", "com.apple.dt.Xcode", "-"],
            check=True, capture_output=True).stdout
    except (OSError, subprocess.CalledProcessError):
        return []
    accounts = plistlib.loads(raw).get("IDEProvisioningTeamByIdentifier", {})
    teams = {
        team["teamID"]: team.get("teamName", "")
        for account in accounts.values()
        for team in account
        if team.get("isFreeProvisioningTeam")
    }
    return sorted(teams.items())


def resolve_team(requested):
    if requested:
        return requested
    teams = free_teams()
    if len(teams) == 1:
        return teams[0][0]
    if not teams:
        sys.exit(
            "No free provisioning team found. Sign in to Xcode with your Apple ID "
            "(Settings > Accounts), then retry, or pass FREE_TEAM=<team id>.")
    listing = "\n".join(f"  {team_id}  {name}" for team_id, name in teams)
    sys.exit(f"Several free teams found; pass FREE_TEAM=<team id>:\n{listing}")


def free_spec(spec, team, bundle_id):
    spec["name"] = "HeelerFree"
    spec["settings"]["base"]["DEVELOPMENT_TEAM"] = team
    spec["targets"] = {
        name: target for name, target in spec["targets"].items()
        if name not in DROPPED_TARGETS
    }

    app = spec["targets"]["Heeler"]
    app["dependencies"] = [
        dependency for dependency in app["dependencies"]
        if dependency.get("target") not in DROPPED_TARGETS
    ]
    # XcodeGen writes both files from these properties, so they must not
    # point at the committed ones.
    app["entitlements"] = {"path": str(OUT / "Heeler.entitlements"), "properties": {}}
    app["info"]["path"] = str(OUT / "Info.plist")
    # Off its info path, the committed Info.plist would be copied in as a
    # resource and collide with the generated one.
    for source in app["sources"]:
        if isinstance(source, dict) and source.get("path") == "Sources/Heeler":
            source.setdefault("excludes", []).append("Info.plist")

    settings = app["settings"]["base"]
    settings["PRODUCT_BUNDLE_IDENTIFIER"] = bundle_id
    settings.pop("INFOPLIST_KEY_NSSupportsLiveActivities", None)
    settings["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] = "$(inherited) HEELER_FREE_BUILD"

    scheme = spec["schemes"]["Heeler"]
    scheme.pop("test", None)
    return spec


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--team", default="")
    parser.add_argument("--bundle-id", default="")
    args = parser.parse_args()

    team = resolve_team(args.team)
    # Bundle ids are global across Apple's developer accounts; the team id
    # suffix keeps a fork's id from colliding with another fork's.
    bundle_id = args.bundle_id or f"dev.heeler.free.t{team.lower()}"

    spec = yaml.safe_load((ROOT / "project.yml").read_text())
    OUT.mkdir(parents=True, exist_ok=True)
    spec_path = OUT / "project.yml"
    spec_path.write_text(yaml.safe_dump(free_spec(spec, team, bundle_id), sort_keys=False))

    subprocess.run(
        ["xcodegen", "generate", "--quiet", "--spec", str(spec_path),
         "--project-root", str(ROOT), "--project", str(ROOT)],
        check=True)
    (OUT / "bundle-id").write_text(bundle_id + "\n")
    print(f"Generated HeelerFree.xcodeproj for team {team}, bundle id {bundle_id}")


if __name__ == "__main__":
    main()
