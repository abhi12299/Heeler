import { test, suite } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

import {
  encodePairingCode,
  decodePairingCode,
  PairingCodeError,
} from "../src/envelope.js";

const vectors = JSON.parse(
  readFileSync(new URL("../test-vectors/pairing-code-v1.json", import.meta.url), "utf8"),
);

/** Convert a decoded payload (seed as Buffer) to the vector shape (seed as base64url). */
function toVectorShape(payload) {
  const shape = {
    addresses: payload.addresses,
    port: payload.port,
    username: payload.username,
  };
  if (payload.hostKeyFingerprint !== undefined) {
    shape.hostKeyFingerprint = payload.hostKeyFingerprint;
  }
  if (payload.auth !== undefined) {
    shape.auth = payload.auth;
  }
  if (payload.bootstrapSeed !== undefined) {
    shape.bootstrapSeed = payload.bootstrapSeed.toString("base64url");
  }
  if (payload.expiresAt !== undefined) {
    shape.expiresAt = payload.expiresAt;
  }
  return shape;
}

/** Convert a vector payload (seed as base64url) to the encode input shape (seed as Buffer). */
function fromVectorShape(payload) {
  const input = { ...payload };
  if (input.bootstrapSeed !== undefined) {
    input.bootstrapSeed = Buffer.from(input.bootstrapSeed, "base64url");
  }
  return input;
}

suite("shared vectors", () => {
  test("vector file has cases", () => {
    assert.ok(vectors.valid.length >= 3);
    assert.ok(vectors.valid.some((v) => v.payload.auth === "tailscale"));
    assert.ok(vectors.invalid.length >= 10);
  });

  for (const vector of vectors.valid) {
    test(`decodes: ${vector.name}`, () => {
      const decoded = decodePairingCode(vector.code);
      assert.deepEqual(toVectorShape(decoded), vector.payload);
    });
  }

  for (const vector of vectors.valid.filter((v) => !v.decodeOnly)) {
    test(`encodes canonically: ${vector.name}`, () => {
      assert.equal(encodePairingCode(fromVectorShape(vector.payload)), vector.code);
    });
  }

  for (const vector of vectors.invalid) {
    test(`rejects (${vector.error}): ${vector.name}`, () => {
      assert.throws(
        () => decodePairingCode(vector.code),
        (error) => error instanceof PairingCodeError && error.code === vector.error,
      );
    });
  }
});

suite("encodePairingCode", () => {
  const base = {
    addresses: ["192.168.1.42"],
    port: 22,
    username: "ada",
    hostKeyFingerprint: "SHA256:6+jncNdibsG2cqvfoLApGrO8CvIwAEMzsB+IilOs8tg",
  };

  test("round-trips through decode", () => {
    const decoded = decodePairingCode(encodePairingCode(base));
    assert.deepEqual(decoded, base);
  });

  test("rejects invalid payloads before encoding", () => {
    const bads = [
      { ...base, addresses: [] },
      { ...base, port: 0 },
      { ...base, port: 22.5 },
      { ...base, username: "" },
      { ...base, hostKeyFingerprint: "MD5:abc" },
      { ...base, bootstrapSeed: Buffer.alloc(31), expiresAt: 1753305600 },
      { ...base, bootstrapSeed: Buffer.alloc(32) },
      { ...base, expiresAt: 1753305600 },
    ];
    for (const bad of bads) {
      assert.throws(
        () => encodePairingCode(bad),
        (error) => error instanceof PairingCodeError && error.code === "bad_payload",
      );
    }
  });

  test("round-trips a tailscale code with and without a fingerprint", () => {
    const { hostKeyFingerprint, ...withoutFingerprint } = base;
    for (const payload of [
      { ...withoutFingerprint, auth: "tailscale" },
      { ...base, auth: "tailscale" },
    ]) {
      assert.deepEqual(decodePairingCode(encodePairingCode(payload)), payload);
    }
  });

  test("emits auth after fp and before seed", () => {
    const code = encodePairingCode({ ...base, auth: "tailscale" });
    const json = Buffer.from(code.split(":")[2], "base64url").toString("utf8");
    assert.deepEqual(Object.keys(JSON.parse(json)), ["addrs", "port", "user", "fp", "auth"]);
  });

  test("rejects tailscale payloads that carry a Bootstrap Key or a bad auth", () => {
    const { hostKeyFingerprint, ...withoutFingerprint } = base;
    const bads = [
      withoutFingerprint,
      { ...withoutFingerprint, auth: "openssh" },
      { ...base, auth: "" },
      { ...withoutFingerprint, auth: "tailscale", bootstrapSeed: Buffer.alloc(32), expiresAt: 1 },
      { ...withoutFingerprint, auth: "tailscale", expiresAt: 1753305600 },
      { ...base, auth: "tailscale", hostKeyFingerprint: "MD5:abc" },
    ];
    for (const bad of bads) {
      assert.throws(
        () => encodePairingCode(bad),
        (error) => error instanceof PairingCodeError && error.code === "bad_payload",
      );
    }
  });

  test("round-trips a bootstrap seed as raw bytes", () => {
    const seed = Buffer.from(Array.from({ length: 32 }, (_, i) => 255 - i));
    const decoded = decodePairingCode(
      encodePairingCode({ ...base, bootstrapSeed: seed, expiresAt: 1753305600 }),
    );
    assert.deepEqual(decoded.bootstrapSeed, seed);
    assert.equal(decoded.expiresAt, 1753305600);
  });
});
