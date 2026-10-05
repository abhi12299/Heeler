<div align="center">

<img src="docs/images/logo.png" width="96" alt="Heeler logo" />

# Heeler

<a href="https://testflight.apple.com/join/aXSxRn4r"><img src="docs/images/testflight-badge.svg" alt="Available on TestFlight" height="40" /></a>
<a href="https://apps.apple.com/us/app/heeler-for-herdr/id6797263135"><img src="https://toolbox.marketingtools.apple.com/api/badges/download-on-the-app-store/black/en-us?size=250x83" alt="Download on the App Store" height="40" /></a>

**A native iOS companion app for [herdr](https://herdr.dev) — an agent-first terminal runtime.**

[![GitHub stars](https://img.shields.io/github/stars/ZingerLittleBee/Heeler?style=flat-square&color=E8B923&logo=github&logoColor=white)](https://github.com/ZingerLittleBee/Heeler/stargazers)
[![CI](https://img.shields.io/github/actions/workflow/status/ZingerLittleBee/Heeler/ci.yml?branch=main&label=CI&style=flat-square)](https://github.com/ZingerLittleBee/Heeler/actions/workflows/ci.yml)
[![License: Apache 2.0](https://img.shields.io/badge/License-Apache_2.0-6F42C1?style=flat-square)](LICENSE)
[![Swift](https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white&style=flat-square)](https://www.swift.org)
[![iOS](https://img.shields.io/badge/iOS-18%2B-000000?logo=apple&logoColor=white&style=flat-square)](https://developer.apple.com/ios/)
[![App Store](https://img.shields.io/badge/App_Store-available-0D96F6?logo=apple&logoColor=white&style=flat-square)](https://apps.apple.com/us/app/heeler-for-herdr/id6797263135)

<a href="https://trendshift.io/repositories/151670?utm_source=repository-badge&amp;utm_medium=badge&amp;utm_campaign=badge-repository-151670" target="_blank" rel="noopener noreferrer"><img src="https://trendshift.io/api/badge/repositories/151670" alt="ZingerLittleBee%2FHeeler | Trendshift" width="250" height="55"/></a>

English | [简体中文](./README-zh.md)

</div>

---

Heeler is an **agent console**: a native dashboard of every coding agent running on your machines, sorted by who needs you. Open an Agent to read and steer its live terminal, draft with the full iOS keyboard in a native Composer, and Send the complete message once — all over plain SSH.

## Screenshots

| Agent Console | Direct Input + Terminal keyboard | Live terminal |
| --- | --- | --- |
| <img src="docs/images/console-iphone.png" width="240" alt="Agent Console listing Agents across Hosts with their status on iPhone" /> | <img src="docs/images/agent-iphone.png" width="240" alt="Agent Direct Input with shortcuts and a full Terminal keyboard on iPhone" /> | <img src="docs/images/live-terminal-iphone.png" width="240" alt="Agent's live terminal with Direct Input on iPhone" /> |

| Changes | File diff | Terminals |
| --- | --- | --- |
| <img src="docs/images/changes-iphone.png" width="240" alt="Changes listing a Checkout's staged and unstaged files on iPhone" /> | <img src="docs/images/diff-iphone.png" width="240" alt="A changed JSON file with its edited words highlighted on iPhone" /> | <img src="docs/images/terminal-iphone.png" width="240" alt="Terminals tab listing shell panes by Host and Workspace on iPhone" /> |

| Skills | Hosts | Live Activity |
| --- | --- | --- |
| <img src="docs/images/skills-iphone.png" width="240" alt="Composer Skills suggestions on iPhone" /> | <img src="docs/images/hosts-iphone.png" width="240" alt="Hosts tab grouping Hosts by connection status with their latency on iPhone" /> | <img src="docs/images/live-activity-iphone.png" width="240" alt="Lock-screen Live Activity tracking Agents on iPhone" /> |

<a href="docs/ipad-screenshots.md"><img src="docs/images/windowed-ipad.png" width="760" alt="Heeler in a floating iPad window" /></a>

[View iPad screenshots](docs/ipad-screenshots.md)

## Features

- **Console** — every Agent on every machine in one status-sorted list
  (Blocked first), filterable by Host, updated live.
- **Attach** — the Agent's real terminal rendered by libghostty: native
  scrollback, momentum touch scrolling that also drives full-screen TUIs,
  long-press selection, takeover of a stale terminal owner, and quietly
  collected web links to open later.
- **Composer** — draft locally with the full iOS keyboard (autocorrect, IME,
  dictation), then Send once; the tools keyboard adds Agent control keys,
  Agent Skills, reusable Snippets, and terminal appearance.
- **Terminal** — open a plain shell in the Agent's directory, with Text and
  Keys modes and one reused tab per Workspace.
- **Attachments** — stage a photo or a file up to 64 MiB onto the Host over
  SFTP and insert its path into the draft.
- **QR pairing** — scan a Pairing Code to add a machine; keys are generated
  on device, private keys stay in the Keychain, and the code pins the host
  key fingerprint.
- **Notifications + Live Activities** — end-to-end encrypted pushes when an
  Agent goes Blocked or Done, and a lock-screen / Dynamic Island banner
  tracking Agents in real time; the relay can never read the content
  ([PRIVACY.md](PRIVACY.md)).
- **Worktrees** — start an Agent on a clean checkout of the workspace's repo.
- **Appearance** — System, Light, or Dark; 30 terminal themes with separate
  Light and Dark slots; bundled JetBrains Mono and IBM Plex Mono; pinch to
  zoom.
- **Jump Host** — reach unroutable machines through an SSH jump, with keys
  verified at both hops.

## How it connects

On macOS and Linux Hosts, Heeler speaks herdr's JSON API over SSH: each request opens a
direct-streamlocal channel onto `herdr.sock`, one long-lived channel carries
the event stream, and interactive terminals run `herdr agent attach
--takeover` on an SSH PTY. The only prerequisites are SSH access and a
running herdr — no server changes, no extra packages. The SSH server must
allow stream-local forwarding (the OpenSSH default); onboarding calls it out
when it's disabled.

Native Windows Hosts (herdr >= 0.9.3) connect over SSH and are added manually.

Unroutable machines can sit behind an SSH Jump Host:

- [Set up remote access step by step](docs/guides/vps-jump-host-setup.md)
- [Architecture, security boundaries, and the VPS runbook](docs/guides/vps-jump-host.md)

## Installation

Install Heeler from the [App Store](https://apps.apple.com/us/app/heeler-for-herdr/id6797263135)
or [TestFlight](https://testflight.apple.com/join/aXSxRn4r).

- **macOS / Linux:** Install [herdr](https://herdr.dev/docs/install/), enable SSH,
  then follow the pairing steps below.
- **Native Windows:** Follow the [Windows setup guide](docs/guides/windows-setup.md).

## Adding a machine

On a macOS or Linux machine running herdr (Node >= 20, herdr >= 0.7.5, OpenSSH server on —
macOS: **System Settings > General > Sharing > Remote Login**):

```bash
herdr plugin install ZingerLittleBee/Heeler/plugin --ref main --yes
herdr plugin action invoke heeler.pair
```

Scan the Pairing Code QR it shows and the machine is added as a Host — the
code carries the addresses, the host key fingerprint, and SSH key enrollment.
The same [plugin](plugin/README.md) delivers the encrypted notifications once
you enable them for the Host in the app.

## This fork: free Apple ID build and Tailscale SSH

This fork ([abhi12299/Heeler](https://github.com/abhi12299/Heeler)) adds two
things upstream does not ship.

### Free Apple ID build

No paid Apple Developer account is needed to run Heeler on your own iPhone:

1. In Xcode, **Settings > Accounts**, sign in with your Apple ID. That creates
   a free Personal Team.
2. Connect the iPhone by USB, unlock it, and tap **Trust**. Turn on
   **Settings > Privacy & Security > Developer Mode** (the phone restarts).
3. Run `make free-install`. It generates `HeelerFree.xcodeproj` from
   `project.yml` (`scripts/free-build/generate-free-project.py`), then builds,
   installs, and launches. With several free teams on the Mac, pass
   `FREE_TEAM=<team id>`. On the first launch, trust the developer under
   **Settings > General > VPN & Device Management** if iOS asks you to.

A free team cannot sign push or app groups, so the free build drops the
Notification Service and Widgets extensions and both entitlements. The trade-offs:

- no push and no lock-screen Live Activity. **Background Alerts** stand in for
  push (on by default, Settings > Notifications): Heeler keeps running in the
  background on a silent, mixable audio session and posts the Done / needs
  input notifications itself from the live event stream. They stop if you swipe
  Heeler away or restart the phone (open it again to resume), cost some battery,
  and do not pause or duck other audio;
- the build expires after **7 days** — run `make free-install` again to renew it;
- a free team may sideload at most **3 apps** per device.

The committed project, entitlements, and Info.plist are untouched; the free
project is generated and git-ignored.

### Custom Agents

**New Agent > Custom Agents** runs your own shell aliases and functions. A
Custom Agent named `cg` types `cg` into the new pane's interactive shell, where
your `~/.zshrc` aliases exist, and herdr picks up the Agent it starts just as
if you had typed it. herdr's own launch can't do this, because it only runs a
supported Agent's executable directly. A profile can also set a different
command, extra arguments, and `KEY=VALUE` environment (`~` and `$HOME` resolve
to the Host's home). If the command starts no Agent within 15 seconds, the
launch fails and shows what the shell printed (for example
`command not found`). The picker offers each profile wherever the Agent it
starts is installed.

### Tailscale SSH Hosts

A machine with [Tailscale SSH](https://tailscale.com/kb/1193/tailscale-ssh)
on (`tailscale set --ssh`) can be a Host with no OpenSSH server at all — on
macOS, Remote Login can stay off. tailscaled answers port 22 on the machine's
tailnet addresses and authorizes by the phone's tailnet identity and your
tailnet policy, so nothing is enrolled on the machine.

- **Add by hand:** Add Host, address = tailnet IP or MagicDNS name, port 22,
  user = your account on the machine, method **Tailscale SSH**. Trust the host
  key on first connect: it is tailscaled's own key, reached over the
  WireGuard-authenticated tailnet.
- **Or pair:** install this fork's plugin and invoke the pairing action:

  ```bash
  herdr plugin install abhi12299/Heeler/plugin --ref main --yes
  herdr plugin action invoke heeler.pair
  ```

  On a machine with Tailscale SSH serving and no OpenSSH host key, the popup
  shows a Tailscale SSH Pairing Code (force it with `"auth": "tailscale"` in
  `pair.json`). The code holds only the addresses and the user — no key, no
  expiry.

If your tailnet policy uses `check` mode, Heeler shows a **Tailscale SSH
check** card with the login link while tailscaled holds the connection.
Approve it in the browser and the connection continues; one approval lasts
for the policy's check period. The policy must allow your account as the SSH
user (`"users": ["<you>"]`) and must not disable forwarding: Heeler reaches
herdr's socket through stream-local forwarding, which Tailscale SSH permits
inside your home directory.

## Stack

- SwiftUI, iOS 18+, iPhone and iPad. iPad support is restored in 0.1.8 with Magic Keyboard shortcuts, multiwindow, and drag and drop.
- The repository-local `Packages/HeelerSSH` (libssh2 + OpenSSL) for SSH
- [libghostty-spm](https://github.com/lakr233/libghostty-spm) for terminal emulation and Metal rendering

See `docs/adr/` for why — the transport story in particular is not obvious.

## Contributing

Issues and PRs are welcome — see [CONTRIBUTING.md](CONTRIBUTING.md) for
layout, build/test, and conventions.

## Status

Released on the [App Store](https://apps.apple.com/us/app/heeler-for-herdr/id6797263135).
It is not yet available in every country or region; where it is missing, the
[TestFlight](https://testflight.apple.com/join/aXSxRn4r) build stays available.
Built for personal use first and shaped by daily driving, so expect rough edges and
fast iteration. Not affiliated with the herdr project.
