---
status: accepted
---

# Native Windows Hosts use herdr's supported SSH exec protocols

Heeler supports manual SSH connections to native Windows herdr, without WSL
or a separate Host-side bridge service (#399). Unix Hosts keep ADR 0011's
direct-streamlocal transport and ADR 0015's PTY terminal attach. Windows
uses `herdr remote-api-bridge` for API requests and Events, and
`herdr terminal session control` for live terminals.

## Evidence and decision

Source-reviewed against herdr v0.9.3, commit
`7b116c05bfda646af39d2524c54e70c751f57ee8`. This is source evidence, not
Windows runtime acceptance.

- [remote.rs](https://github.com/herdrdev/herdr/blob/v0.9.3/src/remote.rs)
  provides `remote-api-bridge --check`, reporting `herdr-api-bridge-v1`.
  The bridge connects to the selected API endpoint and forwards stdio. It
  does not start a missing herdr server.
- [ipc.rs](https://github.com/herdrdev/herdr/blob/v0.9.3/src/ipc.rs)
  maps Windows endpoint paths to named pipes. The `.sock` marker is not a
  Unix socket that SSH can forward.
- [terminal_sessions.rs](https://github.com/herdrdev/herdr/blob/v0.9.3/src/client/terminal_sessions.rs)
  exposes a cross-platform NDJSON controller with ANSI frames, base64 raw
  input, semantic mouse/scroll, resize, and release. Windows direct terminal
  attach remains unavailable.
- [Microsoft's Windows OpenSSH configuration](https://learn.microsoft.com/en-us/windows-server/administration/openssh/openssh-server-configuration)
  documents cmd as the initial DefaultShell, configurable PowerShell shells,
  and the absence of stream-local forwarding configuration.

The official CLI protocols avoid coupling the app to herdr's internal
named-pipe naming and binary client protocol. They add no dependency or
Host installation beyond herdr and Windows OpenSSH. This platform-specific
transport never activates after a Unix forwarding refusal.

## Consequences

- Detect Windows and discover USERPROFILE and the herdr configuration root
  once per Transport. Honor XDG_CONFIG_HOME before APPDATA. Set the selected
  session through PowerShell environment variables, clearing inherited
  HERDR_SOCKET_PATH and HERDR_CLIENT_SOCKET_PATH overrides. Let herdr resolve
  default and named endpoints; pipe identity can
  depend on the exact path spelling. Only an explicit absolute endpoint sets
  HERDR_SOCKET_PATH.
  Use UTF-16LE EncodedCommand for cmd and PowerShell login shells; paths and
  opaque targets remain literals inside the script.
- Keep absolute Unix API endpoints as literal stream-local paths, without a
  HOME probe or shell quoting restrictions. Only exec commands need shell
  quoting; the SSH channel retains absolute-path and NUL validation.
- Discard account-shell startup output until the app's stream marker. Request
  channels hold stdin open until their response arrives, preserving Windows
  bridge output. Keep the existing dispatch hooks and subscription ack rule.
- API, Events, SFTP, and terminals all consume SSH session slots on Windows.
  Share a nine-channel ceiling below OpenSSH's default MaxSessions of ten.
- Controller frames describe a viewport, not the original TUI byte stream.
  Advertise a virtual alternate screen, SGR mouse, and bracketed paste; send
  mouse and scroll as semantic controller commands so herdr consults the
  actual pane's modes. Keep ordered raw input and resize delivery.
- Start the selected Windows herdr session before connecting. Automatic
  Windows server wake is outside this implementation.
- Pairing and automatic key enrollment remain Unix-only. Changes and Skills
  use POSIX scripts. Uploads and notification registration require a separate
  Windows ACL design; synthetic SFTP mode bits do not prove private access.
  Refuse these features explicitly before issuing their remote operations.

Local tests cover protocol conversion, paths, admission, and real SSH exec
lifecycle. Follow [the Windows acceptance checklist](../guides/native-windows-testing.md)
for native shell, named-pipe, terminal, and reconnect verification.
