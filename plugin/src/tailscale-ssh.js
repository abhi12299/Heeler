// Tailscale SSH detection for the pairing popup (#355, #358).
//
// Tailscale SSH intercepts port 22 for connections arriving over the tailnet:
// it answers with tailscaled's own host key and never reads authorized_keys,
// so the forced command that performs Enrollment cannot run there. Two uses:
//
// - OpenSSH mode: a Pairing Code advertising a Tailscale address on port 22
//   would fail after the scan, on the phone, with nothing on the Host to
//   explain it. Say so while the checklist is still open and `pair.json` can
//   still be edited.
// - Tailscale mode: the tailnet identity and ACL authorize the phone, so the
//   code carries this node's tailnet addresses and no Bootstrap Key at all.

import { spawnSync } from "node:child_process";

import { fingerprintPublicKeyLine } from "./host-key.js";

// The only port Tailscale SSH takes over.
export const TAILSCALE_SSH_PORT = 22;

// herdr may start plugin processes without the user's shell PATH, so the
// Homebrew prefixes (Apple silicon, then Intel) are tried by absolute path.
// The macOS app builds do not put the CLI on PATH either; the last two are the
// paths inside the app bundle, in both spellings shipped over the years -- a
// case-sensitive volume gets only the one it has.
const TAILSCALE_COMMANDS = [
  "tailscale",
  "/opt/homebrew/bin/tailscale",
  "/usr/local/bin/tailscale",
  "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
  "/Applications/Tailscale.app/Contents/MacOS/tailscale",
];

// Two probes run back to back before the warning can appear, and a wedged
// tailscaled reaches the timeout rather than answering. Keep the pair short
// enough that the checklist is never unresponsive for long; a timeout also
// ends the search, since every CLI location talks to the same tailscaled.
const COMMAND_TIMEOUT_MS = 800;

/**
 * Whether an address *could* be a tailnet one: 100.64/10 CGNAT or Tailscale's
 * ULA prefix. Only a coarse screen for whether probing is worth a subprocess
 * at all -- 100.64/10 is the whole carrier-grade NAT range, and hosting
 * providers hand those out on ordinary interfaces (measured on a VPS whose
 * enp6s18 held 100.114.1.129 while tailscale0 held 100.73.39.6). Deciding
 * which addresses tailscaled actually answers for needs `tailnetAddresses`.
 *
 * @param {string} address
 * @returns {boolean}
 */
export function mayBeTailscaleAddress(address) {
  if (typeof address !== "string") return false;
  const [a, b] = address.split(".").map(Number);
  if (a === 100 && b >= 64 && b <= 127) return true; // 100.64/10 CGNAT
  return /^fd7a:115c:a1e0\b/i.test(address); // fd7a:115c:a1e0::/48
}

function normalize(address) {
  return typeof address === "string" ? address.split("%")[0].toLowerCase() : "";
}

// The addresses tailscaled reports as this node's own, and so exactly the
// ones whose port 22 it takes over. Anything else in 100.64/10 belongs to
// another interface and is none of its business.
function tailnetAddresses(output) {
  const addresses = parse(output)?.Self?.TailscaleIPs;
  return Array.isArray(addresses) ? addresses.filter((a) => typeof a === "string") : [];
}

/**
 * Run `tailscale <args>` at the first location that answers, or null when
 * none does. A missing binary, a non-zero exit (logged out, wrong build) and
 * a timeout are all "no answer".
 *
 * @param {string[]} args
 * @param {{spawnFn?: typeof spawnSync}} [deps]
 * @returns {string | null}
 */
export function runTailscale(args, { spawnFn = spawnSync } = {}) {
  for (const command of TAILSCALE_COMMANDS) {
    const result = spawnFn(command, args, {
      encoding: "utf8",
      timeout: COMMAND_TIMEOUT_MS,
    });
    if (result.error?.code === "ETIMEDOUT") return null;
    if (result.error || result.status !== 0) continue;
    return result.stdout;
  }
  return null;
}

function parse(output) {
  if (typeof output !== "string") return null;
  try {
    const parsed = JSON.parse(output);
    return parsed !== null && typeof parsed === "object" ? parsed : null;
  } catch {
    return null;
  }
}

// `tailscale debug prefs` is the only surface measured to answer this. On a
// live 1.102.4 host it reported RunSSH true while serving and false right
// after `tailscale set --ssh=false`. It is a debug command with no stability
// promise, hence the second probe below.
function prefsSayEnabled(output) {
  return parse(output)?.RunSSH === true;
}

// `tailscale status --json` carries a documented `sshHostKeys` ("the node's
// SSH host keys, if known") that upstream fills in for a PeerStatus. Measured
// on 1.102.4 it was absent from Self and from all four peers whether or not
// SSH was serving, so this never fires today; it stays as the fallback for
// the day the debug surface moves. Self.CapMap is not usable in its place --
// `cap/ssh` and `ssh-behavior-v1` are ACL grants and survive --ssh=false.
function statusSaysEnabled(output) {
  const keys = parse(output)?.Self?.sshHostKeys;
  return Array.isArray(keys) && keys.length > 0;
}

// This node's MagicDNS name, without the trailing root dot status reports
// ("host.tailnet.ts.net."). Null when MagicDNS is off or the shape changed.
function magicDNSName(output) {
  const name = parse(output)?.Self?.DNSName;
  if (typeof name !== "string") return null;
  const trimmed = name.replace(/\.$/, "");
  return trimmed.length > 0 && !/\s/.test(trimmed) ? trimmed : null;
}

// A pinned fingerprint that matches nothing would fail pairing outright, so
// only trust a line whose wire blob opens with its own key type name (an SSH
// string: uint32 length, then the name) rather than any base64 at all.
function blobNamesItsType(line) {
  const [keyType, blob] = line.trim().split(/\s+/);
  if (!keyType || !blob) return false;
  const bytes = Buffer.from(blob, "base64");
  if (bytes.length < 4) return false;
  const length = bytes.readUInt32BE(0);
  return length === keyType.length && bytes.subarray(4, 4 + length).toString("latin1") === keyType;
}

// Key types in the order the app is expected to negotiate them, mirroring
// host-key.js for OpenSSH.
const HOST_KEY_PREFERENCE = ["ssh-ed25519", "ecdsa-", "ssh-rsa"];

/**
 * The fingerprint of tailscaled's own host key, when `status --json` lists
 * this node's `sshHostKeys`. The key files themselves live root-only under
 * tailscaled's state directory, and the field was absent from Self on every
 * host measured, so this is normally null and the app trusts the key on
 * first use. Never a guess: an unparseable list yields null.
 *
 * @param {unknown} keys `Self.sshHostKeys`
 * @returns {string | null}
 */
export function tailscaleHostKeyFingerprint(keys) {
  if (!Array.isArray(keys)) return null;
  const parsed = [];
  for (const line of keys) {
    if (typeof line !== "string" || !blobNamesItsType(line)) continue;
    try {
      parsed.push(fingerprintPublicKeyLine(line));
    } catch {
      // Skip a line that is not an SSH public key.
    }
  }
  for (const prefix of HOST_KEY_PREFERENCE) {
    const match = parsed.find(({ keyType }) => keyType.startsWith(prefix));
    if (match) return match.fingerprint;
  }
  return null;
}

/**
 * Whether Tailscale SSH is serving here, which addresses it serves on, and
 * what else this node's status says about reaching it.
 *
 * Every probe is yes-only: a machine without the CLI, a logged-out
 * tailscaled, or an output shape that changed all read as "not serving" and
 * warn about nothing. Under-warning leaves today's behavior; over-warning
 * would put a false alarm on every pairing. `addresses` empty means the same
 * thing -- without knowing which addresses tailscaled owns there is nothing
 * safe to point at. `dnsName` and `hostKeyFingerprint` are likewise null
 * unless serving.
 *
 * @param {{run?: (args: string[]) => string | null}} [deps]
 * @returns {{enabled: boolean, addresses: string[], dnsName: string | null,
 *            hostKeyFingerprint: string | null}}
 */
export function detectTailscaleSSH({ run = runTailscale } = {}) {
  const status = run(["status", "--json"]);
  const enabled = prefsSayEnabled(run(["debug", "prefs"])) || statusSaysEnabled(status);
  if (!enabled) {
    return { enabled, addresses: [], dnsName: null, hostKeyFingerprint: null };
  }
  return {
    enabled,
    addresses: tailnetAddresses(status),
    dnsName: magicDNSName(status),
    hostKeyFingerprint: tailscaleHostKeyFingerprint(parse(status)?.Self?.sshHostKeys),
  };
}

/**
 * The checklist for a Tailscale-mode Pairing Code: this node's tailnet IPv4
 * addresses, then its MagicDNS name, then its tailnet IPv6 addresses. IPv4
 * and MagicDNS are pre-checked; IPv6 stays available but unchecked.
 *
 * @param {{addresses?: string[], dnsName?: string | null}} tailscale
 * @returns {{address: string, family: string, interfaceName: string, preChecked: boolean}[]}
 */
export function tailnetCandidates(tailscale) {
  const addresses = [...new Set((tailscale?.addresses ?? []).map(normalize))].filter(Boolean);
  const ipv4 = addresses.filter((address) => !address.includes(":"));
  const ipv6 = addresses.filter((address) => address.includes(":"));
  const entry = (address, family, preChecked) => ({
    address,
    family,
    interfaceName: "tailnet",
    preChecked,
  });
  return [
    ...ipv4.map((address) => entry(address, "IPv4", true)),
    ...(tailscale?.dnsName ? [entry(tailscale.dnsName, "MagicDNS", true)] : []),
    ...ipv6.map((address) => entry(address, "IPv6", false)),
  ];
}

/**
 * The checklist warning for a Pairing Code that would send the phone at
 * tailscaled instead of OpenSSH, or null when the selection is fine.
 *
 * @param {{addresses: string[], sshPort: number,
 *          tailscale: {enabled: boolean, addresses: string[]}}} input
 * @returns {string | null}
 */
export function tailscaleSSHConflict({ addresses, sshPort, tailscale }) {
  if (!tailscale?.enabled || sshPort !== TAILSCALE_SSH_PORT) return null;
  const owned = new Set((tailscale.addresses ?? []).map(normalize));
  const intercepted = (addresses ?? []).filter((address) => owned.has(normalize(address)));
  if (intercepted.length === 0) return null;
  return (
    `Tailscale SSH answers port ${TAILSCALE_SSH_PORT} on ${intercepted.join(", ")}.\n` +
    "Pairing there reaches tailscaled, not OpenSSH, and cannot finish.\n" +
    "Set ssh_port in pair.json to a port OpenSSH listens on, or set\n" +
    '"auth": "tailscale" in pair.json and reopen pairing to pair over Tailscale SSH.'
  );
}
