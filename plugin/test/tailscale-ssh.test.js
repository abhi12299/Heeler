import { suite, test } from "node:test";
import assert from "node:assert/strict";

import { publicLineFromSeed } from "../src/bootstrap-key.js";
import {
  detectTailscaleSSH,
  mayBeTailscaleAddress,
  runTailscale,
  tailnetCandidates,
  tailscaleHostKeyFingerprint,
  tailscaleSSHConflict,
} from "../src/tailscale-ssh.js";

const HOMEBREW_ARM = "/opt/homebrew/bin/tailscale";
const HOMEBREW_INTEL = "/usr/local/bin/tailscale";
const NOT_SERVING = { enabled: false, addresses: [], dnsName: null, hostKeyFingerprint: null };
const BUNDLE_UPPER = "/Applications/Tailscale.app/Contents/MacOS/Tailscale";
const BUNDLE_LOWER = "/Applications/Tailscale.app/Contents/MacOS/tailscale";

function fakeSpawn(byCommand) {
  const calls = [];
  const spawnFn = (command, args, options) => {
    calls.push({ command, args, options });
    return byCommand[command] ?? { error: Object.assign(new Error("not found"), { code: "ENOENT" }) };
  };
  return { spawnFn, calls };
}

function fakeRun(responses) {
  const calls = [];
  const run = (args) => {
    calls.push(args.join(" "));
    return responses[args.join(" ")] ?? null;
  };
  return { run, calls };
}

suite("tailscale address screening", () => {
  test("recognizes the CGNAT range Tailscale assigns from", () => {
    assert.equal(mayBeTailscaleAddress("100.64.0.1"), true);
    assert.equal(mayBeTailscaleAddress("100.127.255.254"), true);
    assert.equal(mayBeTailscaleAddress("100.101.102.103"), true);
  });

  test("leaves neighbouring IPv4 ranges alone", () => {
    assert.equal(mayBeTailscaleAddress("100.63.255.255"), false);
    assert.equal(mayBeTailscaleAddress("100.128.0.1"), false);
    assert.equal(mayBeTailscaleAddress("192.168.1.10"), false);
    assert.equal(mayBeTailscaleAddress("10.0.0.4"), false);
  });

  test("recognizes the Tailscale ULA prefix only", () => {
    assert.equal(mayBeTailscaleAddress("fd7a:115c:a1e0::1"), true);
    assert.equal(mayBeTailscaleAddress("FD7A:115C:A1E0:AB12::4"), true);
    assert.equal(mayBeTailscaleAddress("fd00:1234::1"), false);
    assert.equal(mayBeTailscaleAddress("2001:db8::1"), false);
  });

  test("survives a non-string address", () => {
    assert.equal(mayBeTailscaleAddress(undefined), false);
    assert.equal(mayBeTailscaleAddress(null), false);
  });
});

suite("running the tailscale CLI", () => {
  test("uses the one on PATH and stops there", () => {
    const { spawnFn, calls } = fakeSpawn({ tailscale: { status: 0, stdout: "{}" } });

    assert.equal(runTailscale(["status", "--json"], { spawnFn }), "{}");
    assert.deepEqual(calls.map((call) => call.command), ["tailscale"]);
    assert.deepEqual(calls[0].args, ["status", "--json"]);
    assert.ok(calls[0].options.timeout > 0, "a wedged tailscaled must not hang the popup");
  });

  // herdr may start the popup without the shell's PATH; measured on a Mac
  // running Homebrew's tailscaled, the CLI lives only at /opt/homebrew/bin.
  test("falls through to the Homebrew prefixes when PATH has none", () => {
    for (const [path, expected] of [
      [HOMEBREW_ARM, ["tailscale", HOMEBREW_ARM]],
      [HOMEBREW_INTEL, ["tailscale", HOMEBREW_ARM, HOMEBREW_INTEL]],
    ]) {
      const { spawnFn, calls } = fakeSpawn({ [path]: { status: 0, stdout: "up" } });

      assert.equal(runTailscale(["status"], { spawnFn }), "up");
      assert.deepEqual(calls.map((call) => call.command), expected);
    }
  });

  test("falls through to the app bundle when PATH and Homebrew have none", () => {
    const { spawnFn, calls } = fakeSpawn({ [BUNDLE_UPPER]: { status: 0, stdout: "up" } });

    assert.equal(runTailscale(["status"], { spawnFn }), "up");
    assert.deepEqual(calls.map((call) => call.command), [
      "tailscale",
      HOMEBREW_ARM,
      HOMEBREW_INTEL,
      BUNDLE_UPPER,
    ]);
  });

  test("tries the lowercase bundle path a case-sensitive volume would need", () => {
    const { spawnFn, calls } = fakeSpawn({ [BUNDLE_LOWER]: { status: 0, stdout: "up" } });

    assert.equal(runTailscale(["status"], { spawnFn }), "up");
    assert.deepEqual(calls.length, 5);
  });

  test("stops at the first timeout: every location talks to the same tailscaled", () => {
    const { spawnFn, calls } = fakeSpawn({
      tailscale: { error: Object.assign(new Error("timed out"), { code: "ETIMEDOUT" }) },
      [HOMEBREW_ARM]: { status: 0, stdout: "up" },
    });

    assert.equal(runTailscale(["status"], { spawnFn }), null);
    assert.equal(calls.length, 1);
  });

  test("treats a non-zero exit as no answer", () => {
    const { spawnFn } = fakeSpawn({
      tailscale: { status: 1, stdout: "", stderr: "logged out" },
    });

    assert.equal(runTailscale(["debug", "prefs"], { spawnFn }), null);
  });

  test("treats a spawn failure as no answer", () => {
    const { spawnFn, calls } = fakeSpawn({});

    assert.equal(runTailscale(["status"], { spawnFn }), null);
    assert.equal(calls.length, 5, "every candidate location is tried before giving up");
  });
});

suite("tailscale SSH detection", () => {
  // Measured on a live 1.102.4 host: RunSSH is the probe that answers,
  // sshHostKeys is absent either way, and Self.TailscaleIPs names exactly the
  // addresses tailscaled serves on.
  test("reports RunSSH plus the addresses tailscaled owns", () => {
    const { run, calls } = fakeRun({
      "debug prefs": JSON.stringify({ RunSSH: true }),
      "status --json": JSON.stringify({
        Self: { TailscaleIPs: ["100.73.39.6", "fd7a:115c:a1e0::c839:2707"] },
      }),
    });

    assert.deepEqual(detectTailscaleSSH({ run }), {
      enabled: true,
      addresses: ["100.73.39.6", "fd7a:115c:a1e0::c839:2707"],
      dnsName: null,
      hostKeyFingerprint: null,
    });
    assert.deepEqual(calls, ["status --json", "debug prefs"]);
  });

  // Shape measured on a Mac running Homebrew's tailscaled 1.102.5: DNSName
  // carries the root dot, and sshHostKeys is absent from Self.
  test("reports the MagicDNS name without its trailing dot", () => {
    const { run } = fakeRun({
      "debug prefs": JSON.stringify({ RunSSH: true }),
      "status --json": JSON.stringify({
        Self: {
          TailscaleIPs: ["100.125.174.14", "fd7a:115c:a1e0::1"],
          DNSName: "abhi-mac.taild99ff3.ts.net.",
        },
      }),
    });

    assert.deepEqual(detectTailscaleSSH({ run }), {
      enabled: true,
      addresses: ["100.125.174.14", "fd7a:115c:a1e0::1"],
      dnsName: "abhi-mac.taild99ff3.ts.net",
      hostKeyFingerprint: null,
    });
  });

  test("ignores an empty or malformed MagicDNS name", () => {
    for (const DNSName of ["", ".", "a b.ts.net.", 42, null]) {
      const { run } = fakeRun({
        "debug prefs": JSON.stringify({ RunSSH: true }),
        "status --json": JSON.stringify({ Self: { TailscaleIPs: ["100.1.2.3"], DNSName } }),
      });
      assert.equal(detectTailscaleSSH({ run }).dnsName, null, JSON.stringify(DNSName));
    }
  });

  test("falls back to the status host keys when prefs stops answering", () => {
    const { run } = fakeRun({
      "status --json": JSON.stringify({
        Self: { sshHostKeys: ["ssh-ed25519 AAAA"], TailscaleIPs: ["100.73.39.6"] },
      }),
    });

    assert.deepEqual(detectTailscaleSSH({ run }), {
      enabled: true,
      addresses: ["100.73.39.6"],
      dnsName: null,
      hostKeyFingerprint: null,
    });
  });

  test("reads RunSSH false as not serving, and keeps no addresses", () => {
    const { run } = fakeRun({
      "debug prefs": JSON.stringify({ RunSSH: false }),
      "status --json": JSON.stringify({ Self: { TailscaleIPs: ["100.73.39.6"] } }),
    });

    assert.deepEqual(detectTailscaleSSH({ run }), NOT_SERVING);
  });

  test("stays quiet when tailscale is absent or unreadable", () => {
    for (const responses of [
      {},
      { "status --json": "not json", "debug prefs": "not json" },
      { "status --json": "null", "debug prefs": "[]" },
      { "status --json": JSON.stringify({ Self: null }) },
    ]) {
      const { run } = fakeRun(responses);
      assert.deepEqual(detectTailscaleSSH({ run }), NOT_SERVING);
    }
  });

  test("serving with no readable addresses warns about nothing", () => {
    const { run } = fakeRun({ "debug prefs": JSON.stringify({ RunSSH: true }) });

    assert.deepEqual(detectTailscaleSSH({ run }), {
      enabled: true,
      addresses: [],
      dnsName: null,
      hostKeyFingerprint: null,
    });
  });
});

suite("tailscale host key", () => {
  const ED25519 = publicLineFromSeed(Buffer.alloc(32, 7));
  // Only the type name matters for selection; the rest of the blob is filler.
  const RSA = `ssh-rsa ${Buffer.from("\0\0\0\x07ssh-rsa\0\0\0\x03\x01\0\x01", "latin1").toString("base64")}`;

  test("fingerprints the ed25519 key ahead of the others", () => {
    const fingerprint = tailscaleHostKeyFingerprint([RSA, ED25519]);
    assert.match(fingerprint, /^SHA256:[A-Za-z0-9+/]{43}$/);
    assert.equal(fingerprint, tailscaleHostKeyFingerprint([ED25519]));
    assert.notEqual(fingerprint, tailscaleHostKeyFingerprint([RSA]));
  });

  test("is null when nothing parses", () => {
    assert.equal(tailscaleHostKeyFingerprint(undefined), null);
    assert.equal(tailscaleHostKeyFingerprint([]), null);
    assert.equal(tailscaleHostKeyFingerprint(["ssh-ed25519 AAAA"]), null);
    assert.equal(tailscaleHostKeyFingerprint(["not a key", 7]), null);
    // A blob that does not name its own type (here: ed25519 label, rsa blob).
    assert.equal(tailscaleHostKeyFingerprint([`ssh-ed25519 ${RSA.split(" ")[1]}`]), null);
  });

  test("detection reports it when status lists Self's keys", () => {
    const { run } = fakeRun({
      "status --json": JSON.stringify({
        Self: { sshHostKeys: [ED25519], TailscaleIPs: ["100.73.39.6"] },
      }),
    });

    assert.equal(
      detectTailscaleSSH({ run }).hostKeyFingerprint,
      tailscaleHostKeyFingerprint([ED25519]),
    );
  });
});

suite("tailnet candidates", () => {
  test("orders IPv4, then MagicDNS, then IPv6, pre-checking all but IPv6", () => {
    assert.deepEqual(
      tailnetCandidates({
        addresses: ["fd7a:115c:a1e0::1", "100.125.174.14"],
        dnsName: "abhi-mac.taild99ff3.ts.net",
      }),
      [
        { address: "100.125.174.14", family: "IPv4", interfaceName: "tailnet", preChecked: true },
        {
          address: "abhi-mac.taild99ff3.ts.net",
          family: "MagicDNS",
          interfaceName: "tailnet",
          preChecked: true,
        },
        {
          address: "fd7a:115c:a1e0::1",
          family: "IPv6",
          interfaceName: "tailnet",
          preChecked: false,
        },
      ],
    );
  });

  test("works without MagicDNS and drops duplicates and zone ids", () => {
    assert.deepEqual(
      tailnetCandidates({
        addresses: ["100.1.2.3", "FD7A:115C:A1E0::1%utun4", "100.1.2.3"],
        dnsName: null,
      }).map(({ address }) => address),
      ["100.1.2.3", "fd7a:115c:a1e0::1"],
    );
  });

  test("is empty when tailscaled reported nothing", () => {
    assert.deepEqual(tailnetCandidates({ addresses: [], dnsName: null }), []);
    assert.deepEqual(tailnetCandidates(undefined), []);
  });
});

suite("tailscale SSH conflict", () => {
  const serving = {
    sshPort: 22,
    tailscale: { enabled: true, addresses: ["100.73.39.6", "fd7a:115c:a1e0::c839:2707"] },
  };

  test("names only the addresses tailscaled actually answers for", () => {
    const warning = tailscaleSSHConflict({
      ...serving,
      addresses: ["192.168.1.10", "100.73.39.6"],
    });

    assert.match(warning, /100\.73\.39\.6/);
    assert.doesNotMatch(warning, /192\.168\.1\.10/);
    assert.match(warning, /ssh_port/);
    assert.match(warning, /"auth": "tailscale"/);
  });

  // The case that made this address-exact: a hosting provider handed
  // 100.114.1.129 to the VPS's own NIC while tailscale0 held 100.73.39.6.
  // Warning about the NIC address would be a false alarm.
  test("ignores a CGNAT address that belongs to another interface", () => {
    assert.equal(
      tailscaleSSHConflict({ ...serving, addresses: ["100.114.1.129"] }),
      null,
    );
  });

  test("matches an IPv6 address across case and zone id", () => {
    const warning = tailscaleSSHConflict({
      ...serving,
      addresses: ["FD7A:115C:A1E0::C839:2707%tailscale0"],
    });

    assert.match(warning, /FD7A:115C:A1E0::C839:2707/);
  });

  test("says nothing once the code advertises another port", () => {
    assert.equal(
      tailscaleSSHConflict({ ...serving, sshPort: 2222, addresses: ["100.73.39.6"] }),
      null,
    );
  });

  test("says nothing when Tailscale SSH is not serving", () => {
    assert.equal(
      tailscaleSSHConflict({
        sshPort: 22,
        tailscale: { enabled: false, addresses: ["100.73.39.6"] },
        addresses: ["100.73.39.6"],
      }),
      null,
    );
  });

  test("survives an empty or missing selection and an absent probe", () => {
    assert.equal(tailscaleSSHConflict({ ...serving, addresses: [] }), null);
    assert.equal(tailscaleSSHConflict({ ...serving, addresses: undefined }), null);
    assert.equal(
      tailscaleSSHConflict({ sshPort: 22, addresses: ["100.73.39.6"] }),
      null,
    );
  });
});
