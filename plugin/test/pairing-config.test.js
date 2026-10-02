import { afterEach, suite, test } from "node:test";
import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import {
  DEFAULT_PAIRING_AUTH,
  DEFAULT_SSH_PORT,
  readPairingConfig,
} from "../src/pairing-config.js";

let configDir;

afterEach(() => {
  if (configDir) rmSync(configDir, { recursive: true, force: true });
  configDir = undefined;
});

function makeConfigDir() {
  configDir = mkdtempSync(join(tmpdir(), "pairing-config-"));
  return configDir;
}

function writeRawConfig(contents) {
  writeFileSync(join(makeConfigDir(), "pair.json"), contents);
}

function writeConfig(config) {
  writeRawConfig(JSON.stringify(config));
}

suite("pairing config", () => {
  test("defaults to port 22 when pair.json is absent", () => {
    assert.deepEqual(readPairingConfig(makeConfigDir()), {
      sshPort: DEFAULT_SSH_PORT,
      auth: DEFAULT_PAIRING_AUTH,
      warning: null,
      authWarning: null,
    });
  });

  test("defaults when the config directory is unset", () => {
    assert.deepEqual(readPairingConfig(undefined), {
      sshPort: DEFAULT_SSH_PORT,
      auth: DEFAULT_PAIRING_AUTH,
      warning: null,
      authWarning: null,
    });
  });

  test("preserves an explicit OpenSSH port", () => {
    writeConfig({ ssh_port: 2222 });

    assert.deepEqual(readPairingConfig(configDir), { sshPort: 2222, auth: "auto", warning: null, authWarning: null });
  });

  test("warns instead of silently falling back on an unusable port", () => {
    for (const ssh_port of [22.5, 0, -1, 65536, "2222", null]) {
      writeConfig({ ssh_port });

      const { sshPort, warning } = readPairingConfig(configDir);
      assert.equal(sshPort, DEFAULT_SSH_PORT);
      assert.match(warning, /ssh_port/);
      assert.ok(
        warning.includes(JSON.stringify(ssh_port)),
        `warning should quote the rejected value: ${warning}`,
      );

      rmSync(configDir, { recursive: true, force: true });
      configDir = undefined;
    }
  });

  test("accepts the ends of the port range", () => {
    for (const ssh_port of [1, 65535]) {
      writeConfig({ ssh_port });
      assert.deepEqual(readPairingConfig(configDir), {
        sshPort: ssh_port,
        auth: "auto",
        warning: null,
        authWarning: null,
      });
      rmSync(configDir, { recursive: true, force: true });
      configDir = undefined;
    }
  });

  test("ignores unrelated fields", () => {
    writeConfig({ ssh_port: 2222, relay_url: "https://example.com" });

    assert.deepEqual(readPairingConfig(configDir), { sshPort: 2222, auth: "auto", warning: null, authWarning: null });
  });

  test("stays quiet when pair.json omits ssh_port", () => {
    writeConfig({ relay_url: "https://example.com" });

    assert.deepEqual(readPairingConfig(configDir), {
      sshPort: DEFAULT_SSH_PORT,
      auth: DEFAULT_PAIRING_AUTH,
      warning: null,
      authWarning: null,
    });
  });

  test("warns when pair.json is corrupt", () => {
    writeRawConfig("{not json");

    const { sshPort, warning } = readPairingConfig(configDir);
    assert.equal(sshPort, DEFAULT_SSH_PORT);
    assert.match(warning, /not valid JSON/);
  });

  test("warns when pair.json holds something other than an object", () => {
    for (const contents of ["null", "[]", '"2222"']) {
      writeRawConfig(contents);

      const { sshPort, warning } = readPairingConfig(configDir);
      assert.equal(sshPort, DEFAULT_SSH_PORT);
      assert.match(warning, /not a JSON object/);

      rmSync(configDir, { recursive: true, force: true });
      configDir = undefined;
    }
  });

  test("warns when pair.json cannot be read", () => {
    // A directory in pair.json's place fails with EISDIR, standing in for the
    // unreadable-file cases (EACCES) that a test cannot create as root.
    mkdirSync(join(makeConfigDir(), "pair.json"));

    const { sshPort, warning } = readPairingConfig(configDir);
    assert.equal(sshPort, DEFAULT_SSH_PORT);
    assert.match(warning, /could not be read/);
  });

  test("defaults auth to auto", () => {
    assert.equal(DEFAULT_PAIRING_AUTH, "auto");
    writeConfig({ ssh_port: 2222 });

    assert.equal(readPairingConfig(configDir).auth, "auto");
  });

  test("honors each auth mode", () => {
    for (const auth of ["auto", "openssh", "tailscale"]) {
      writeConfig({ auth });
      assert.deepEqual(readPairingConfig(configDir), {
        sshPort: DEFAULT_SSH_PORT,
        auth,
        warning: null,
        authWarning: null,
      });
      rmSync(configDir, { recursive: true, force: true });
      configDir = undefined;
    }
  });

  test("warns instead of silently falling back on an unknown auth", () => {
    for (const auth of ["Tailscale", "ssh", "", null, 1, true]) {
      writeConfig({ auth, ssh_port: 2222 });

      const config = readPairingConfig(configDir);
      assert.equal(config.auth, DEFAULT_PAIRING_AUTH);
      assert.equal(config.sshPort, 2222, "a bad auth must not cost a good ssh_port");
      assert.equal(config.warning, null);
      assert.match(config.authWarning, /auth/);
      assert.ok(
        config.authWarning.includes(JSON.stringify(auth)),
        `warning should quote the rejected value: ${config.authWarning}`,
      );

      rmSync(configDir, { recursive: true, force: true });
      configDir = undefined;
    }
  });

  test("keeps a good auth next to a rejected ssh_port", () => {
    writeConfig({ auth: "tailscale", ssh_port: "2222" });

    const config = readPairingConfig(configDir);
    assert.equal(config.auth, "tailscale");
    assert.equal(config.sshPort, DEFAULT_SSH_PORT);
    assert.match(config.warning, /ssh_port/);
    assert.equal(config.authWarning, null);
  });
});
