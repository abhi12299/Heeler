import { readFileSync } from "node:fs";
import { join } from "node:path";

import { isShellSafeAbsolutePath } from "./envelope.js";

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
 * `addresses` lists addresses (IPs or host names) the phone reaches this
 * machine on that the interface enumeration cannot see: a container behind a
 * published port, a NAT, or a DNS name. They are offered first and
 * pre-checked. A missing or invalid `addresses` means none.
 *
 * `launcher` names an executable that behaves as `herdr` for this instance,
 * used instead of the generated one when this herdr runs outside
 * `~/.config/herdr` (endpoint.js). A missing or invalid `launcher` means none.
 *
 * An override that was written but could not be honored also reports a
 * warning beside the setting it failed to change: `warning` (the file itself
 * and `ssh_port`), `authWarning`, `addressesWarning` or `launcherWarning`.
 * Falling back in silence would hand the operator the exact failure the
 * override was meant to avoid. Having no `pair.json` at all is the ordinary
 * case and warns about nothing.
 *
 * @param {string | undefined} configDir `HERDR_PLUGIN_CONFIG_DIR`, or unset
 * @returns {{sshPort: number, warning: string | null,
 *   auth: "auto"|"openssh"|"tailscale", authWarning: string | null,
 *   addresses: string[], addressesWarning: string | null,
 *   launcher: string | null, launcherWarning: string | null}}
 */
export function readPairingConfig(configDir) {
  const fallback = (warning = null) => ({
    sshPort: DEFAULT_SSH_PORT,
    warning,
    auth: DEFAULT_PAIRING_AUTH,
    authWarning: null,
    addresses: [],
    addressesWarning: null,
    launcher: null,
    launcherWarning: null,
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

  return {
    ...readPort(parsed.ssh_port),
    ...readAuth(parsed.auth),
    ...readAddresses(parsed.addresses),
    ...readLauncher(parsed.launcher),
  };
}

function readPort(port) {
  if (port === undefined) return { sshPort: DEFAULT_SSH_PORT, warning: null };
  if (!Number.isInteger(port) || port < 1 || port > 65535) {
    return {
      sshPort: DEFAULT_SSH_PORT,
      warning: `pair.json ssh_port ${JSON.stringify(port)} is not an integer 1..65535.`,
    };
  }
  return { sshPort: port, warning: null };
}

function readAuth(auth) {
  if (auth === undefined) return { auth: DEFAULT_PAIRING_AUTH, authWarning: null };
  if (!PAIRING_AUTH_MODES.includes(auth)) {
    return {
      auth: DEFAULT_PAIRING_AUTH,
      authWarning:
        `pair.json auth ${JSON.stringify(auth)} is not one of ` +
        `${PAIRING_AUTH_MODES.map((mode) => JSON.stringify(mode)).join(", ")}. ` +
        `Using "${DEFAULT_PAIRING_AUTH}".`,
    };
  }
  return { auth, authWarning: null };
}

// Same rule the Pairing Code envelope enforces: non-empty, no whitespace.
function readAddresses(addresses) {
  if (addresses === undefined) return { addresses: [], addressesWarning: null };
  const valid =
    Array.isArray(addresses) &&
    addresses.every((a) => typeof a === "string" && a.length > 0 && !/\s/.test(a));
  if (!valid) {
    return {
      addresses: [],
      addressesWarning: `pair.json addresses ${JSON.stringify(addresses)} is not a list of addresses without whitespace.`,
    };
  }
  return { addresses: [...new Set(addresses)], addressesWarning: null };
}

// Same rule the Pairing Code v2 envelope enforces on `herdr`.
function readLauncher(launcher) {
  if (launcher === undefined) return { launcher: null, launcherWarning: null };
  if (!isShellSafeAbsolutePath(launcher)) {
    return {
      launcher: null,
      launcherWarning: `pair.json launcher ${JSON.stringify(launcher)} is not an absolute path without quotes, backslashes or control characters.`,
    };
  }
  return { launcher, launcherWarning: null };
}
