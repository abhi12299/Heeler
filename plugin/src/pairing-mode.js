// Which pairing ceremony the popup runs (pair.json `auth`).
//
// - "openssh": the Bootstrap Key ceremony against sshd, pinning the host key
//   under /etc/ssh (ADR 0007).
// - "tailscale": Tailscale SSH serves port 22 and the tailnet ACL authorizes
//   the phone. Nothing is enrolled here; the Pairing Code carries only where
//   to connect and as whom.
//
// Pure so the popup's startup decision is testable without a terminal or a
// tailscaled.

/**
 * Whether the mode decision needs to ask Tailscale before the first screen.
 * "auto" on a machine with an OpenSSH host key stays in OpenSSH mode without
 * asking, so the checklist paints as fast as it always did.
 *
 * @param {{auth: "auto"|"openssh"|"tailscale", hostKeyAvailable: boolean}} input
 * @returns {boolean}
 */
export function needsTailscaleProbe({ auth, hostKeyAvailable }) {
  if (auth === "tailscale") return true;
  if (auth === "openssh") return false;
  return !hostKeyAvailable;
}

/**
 * Decide the pairing mode, or the fatal screen that replaces it.
 *
 * "auto" pairs over Tailscale SSH only when it is serving *and* there is no
 * OpenSSH host key: a machine with both keeps today's ceremony (and its
 * conflict warning), and naming the mode in pair.json overrides either way.
 *
 * @param {{auth: "auto"|"openssh"|"tailscale", hostKeyAvailable: boolean,
 *          tailscaleServing: boolean}} input
 * @returns {"openssh" | "tailscale" | "missing_host_key" | "tailscale_ssh_off"}
 */
export function decidePairingMode({ auth, hostKeyAvailable, tailscaleServing }) {
  if (auth === "tailscale") {
    return tailscaleServing ? "tailscale" : "tailscale_ssh_off";
  }
  if (hostKeyAvailable) return "openssh";
  if (auth !== "openssh" && tailscaleServing) return "tailscale";
  return "missing_host_key";
}
