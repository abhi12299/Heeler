# Accept Tailscale SSH as a Host authenticated by tailnet identity

Upstream refuses Tailscale SSH (#358): pairing enrolls the Device Key through an `authorized_keys` forced command and pins the OpenSSH host key, and tailscaled reads neither. This fork instead treats Tailscale SSH as its own kind of Host, so a Mac can serve herdr to the phone with macOS Remote Login off.

- **Authentication** is SSH `none`. tailscaled authorizes every method by the client's tailnet identity and the tailnet policy and ignores the credential (`ssh/tailssh`, v1.102.5), so offering a key would only pretend. The Host stores no secret and nothing is enrolled on it.
- **`check` policies** hold authentication open (up to 30 minutes) after sending the login URL as an `SSH_MSG_USERAUTH_BANNER`. HeelerSSH's `authenticateNone` reports banners while the request is pending and raises libssh2's per-packet read timeout for the call; the app shows the link app-wide and waits up to five minutes. A refusal also arrives as a banner and is shown verbatim.
- **Host key** is trusted on first use, not pinned from the Pairing Code: tailscaled generates its own keys under a root-only directory when `/etc/ssh` has none (always the case on a Mac with Remote Login off), so the plugin cannot read them. The WireGuard tunnel already authenticates which node answers a tailnet address. A code may still carry `fp`, and the app enforces it when present.
- **Pairing Code** v1 gains an additive `auth: "tailscale"`: no Bootstrap Key, no expiry, `fp` optional. Older apps reject such a code as `bad_payload` rather than misreading it.

## Consequences

- Access is revoked in the tailnet policy, not by removing a key line on the Host; the plugin's revoke screen does not apply.
- herdr's socket must sit under the user's home, `/tmp`, or `/run/user/<uid>` and the policy must leave forwarding on, or tailscaled rejects the direct-streamlocal channel.
- The OpenSSH path is unchanged, including its refusal of a Tailscale SSH server for a Bootstrap Key code.
