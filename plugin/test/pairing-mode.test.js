import { suite, test } from "node:test";
import assert from "node:assert/strict";

import { decidePairingMode, needsTailscaleProbe } from "../src/pairing-mode.js";

suite("tailscale probe before the first screen", () => {
  test("auto asks only when there is no OpenSSH host key", () => {
    assert.equal(needsTailscaleProbe({ auth: "auto", hostKeyAvailable: false }), true);
    assert.equal(needsTailscaleProbe({ auth: "auto", hostKeyAvailable: true }), false);
  });

  test("an explicit mode decides it", () => {
    for (const hostKeyAvailable of [true, false]) {
      assert.equal(needsTailscaleProbe({ auth: "tailscale", hostKeyAvailable }), true);
      assert.equal(needsTailscaleProbe({ auth: "openssh", hostKeyAvailable }), false);
    }
  });
});

suite("pairing mode", () => {
  const cases = [
    // auth, host key, tailscale serving -> mode
    ["auto", true, false, "openssh"],
    ["auto", true, true, "openssh"],
    // The measured Mac: Remote Login never enabled, Tailscale SSH on.
    ["auto", false, true, "tailscale"],
    ["auto", false, false, "missing_host_key"],
    ["openssh", true, true, "openssh"],
    ["openssh", true, false, "openssh"],
    ["openssh", false, true, "missing_host_key"],
    ["openssh", false, false, "missing_host_key"],
    ["tailscale", true, true, "tailscale"],
    ["tailscale", false, true, "tailscale"],
    ["tailscale", true, false, "tailscale_ssh_off"],
    ["tailscale", false, false, "tailscale_ssh_off"],
  ];

  for (const [auth, hostKeyAvailable, tailscaleServing, expected] of cases) {
    test(`${auth}, host key ${hostKeyAvailable}, serving ${tailscaleServing} -> ${expected}`, () => {
      assert.equal(decidePairingMode({ auth, hostKeyAvailable, tailscaleServing }), expected);
    });
  }

  test("a probe that never ran reads as not serving", () => {
    // auto with a host key skips the probe; the popup passes enabled: false.
    assert.equal(
      decidePairingMode({ auth: "auto", hostKeyAvailable: true, tailscaleServing: false }),
      "openssh",
    );
  });
});
