import { readFileSync } from "node:fs";
import { join } from "node:path";

export const DEFAULT_SSH_PORT = 22;

// How the phone is authorized on this machine. "openssh" is the Bootstrap
// Key ceremony against sshd; "tailscale" lets Tailscale SSH's tailnet ACL
// authorize it with nothing enrolled here; "auto" picks between them at
// popup start (see pairing-mode.js).
export const PAIRING_AUTH_MODES = ["auto", "openssh", "tailscale"];
export const DEFAULT_PAIRING_AUTH = "auto";

/**
 * Read the plugin-side `pair.json`. A missing or invalid `ssh_port` uses 22,
 * so a Tailscale-SSH Host can advertise OpenSSH on another port without
 * changing the Pairing Code envelope. A missing or invalid `auth` uses
 * "auto".
 *
 * An override that was written but could not be honored also reports a
 * warning: falling back in silence would hand the operator the exact failure
 * the override was meant to avoid. `warning` covers the file itself and
 * `ssh_port`; `authWarning` covers `auth`, so each lands next to the setting
 * it failed to change. Having no `pair.json` at all is the ordinary case and
 * warns about nothing.
 *
 * @param {string | undefined} configDir `HERDR_PLUGIN_CONFIG_DIR`, or unset
 * @returns {{sshPort: number, auth: "auto"|"openssh"|"tailscale",
 *            warning: string | null, authWarning: string | null}}
 */
export function readPairingConfig(configDir) {
  const fallback = (warning = null) => ({
    sshPort: DEFAULT_SSH_PORT,
    auth: DEFAULT_PAIRING_AUTH,
    warning,
    authWarning: null,
  });
  if (!configDir) return fallback();

  let contents;
  try {
    contents = readFileSync(join(configDir, "pair.json"), "utf8");
  } catch (error) {
    if (error.code === "ENOENT") return fallback();
    return fallback(`pair.json could not be read (${error.code ?? error.message}).`);
  }

  let parsed;
  try {
    parsed = JSON.parse(contents);
  } catch {
    return fallback("pair.json is not valid JSON.");
  }
  if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) {
    return fallback("pair.json is not a JSON object.");
  }

  const config = fallback();

  const port = parsed.ssh_port;
  if (port !== undefined) {
    if (!Number.isInteger(port) || port < 1 || port > 65535) {
      config.warning = `pair.json ssh_port ${JSON.stringify(port)} is not an integer 1..65535.`;
    } else {
      config.sshPort = port;
    }
  }

  const auth = parsed.auth;
  if (auth !== undefined) {
    if (PAIRING_AUTH_MODES.includes(auth)) {
      config.auth = auth;
    } else {
      config.authWarning =
        `pair.json auth ${JSON.stringify(auth)} is not one of ` +
        `${PAIRING_AUTH_MODES.map((mode) => JSON.stringify(mode)).join(", ")}. ` +
        `Using "${DEFAULT_PAIRING_AUTH}".`;
    }
  }
  return config;
}
