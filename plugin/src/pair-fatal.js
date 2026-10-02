// Copy for pairing popup startup failures. The TUI paints these and waits
// for a key so herdr does not close the pane before the user can read them.

export const MISSING_STATE_DIR =
  "HERDR_PLUGIN_STATE_DIR is not set. Run this popup through herdr.";

export const MISSING_HOST_KEY = [
  "No SSH host key found under /etc/ssh.",
  "",
  "Enable Remote Login (System Settings > General > Sharing), or run:",
  "  sudo ssh-keygen -A",
  "Then invoke pairing again.",
  "",
  "Or pair over Tailscale SSH instead: run `tailscale set --ssh`",
  '(with pair.json "auth" unset, "auto", or "tailscale").',
].join("\n");

export const TAILSCALE_SSH_OFF = [
  'pair.json sets "auth": "tailscale", but Tailscale SSH is not serving here.',
  "",
  "Turn it on, then invoke pairing again:",
  "  tailscale set --ssh",
  "",
  'Or remove "auth" from pair.json to pair through OpenSSH.',
].join("\n");

export const MISSING_TAILNET_ADDRESS = [
  "Tailscale SSH is serving, but tailscale status reported no tailnet",
  "address for this machine. Run `tailscale status` and retry once it is up.",
].join("\n");

export const MISSING_ADDRESS =
  "No routable network address found. Connect to a LAN or VPN and retry.";

export function pairingStartFailed(errorMessage) {
  return `Could not start pairing: ${errorMessage}`;
}

export function fatalLines(message) {
  return ["Pairing cannot start", "", message, "", "Press any key to close."];
}
