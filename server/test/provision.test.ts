import { expect, test } from "bun:test";
import { existsSync, mkdtempSync, readdirSync, rmSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

function run(directory: string, extra: string[] = []) {
  return Bun.spawnSync([process.execPath, resolve(import.meta.dir, "../src/provision.ts"), directory,
    "https://calling.example.invalid/openu60", "192.0.2.1", "10.0.0.1", ...extra], { stdout: "pipe", stderr: "pipe" });
}

test("provisioning publishes private configuration together and refuses an existing directory", () => {
  const root = mkdtempSync(join(tmpdir(), "openu60-synthetic-provision-")); const directory = join(root, "config");
  try {
    expect(run(directory).exitCode).toBe(0);
    expect(readdirSync(root)).toEqual(["config"]);
    for (const name of ["calling-server.private.json", "coturn.private.conf", "turn-secret.private"]) {
      expect(statSync(join(directory, name)).mode & 0o777).toBe(0o600);
    }
    expect(statSync(directory).mode & 0o777).toBe(0o700);
    expect(run(directory).exitCode).not.toBe(0);
  } finally { rmSync(root, { recursive: true }); }
});

test("invalid APNs metadata cannot leave a partially initialized credential directory", () => {
  const root = mkdtempSync(join(tmpdir(), "openu60-synthetic-provision-")); const directory = join(root, "config");
  try {
    expect(run(directory, ["/synthetic/key.p8", "bad-team", "bad-key", "test.openu60"]).exitCode).not.toBe(0);
    expect(existsSync(directory)).toBe(false);
    expect(readdirSync(root)).toEqual([]);
  } finally { rmSync(root, { recursive: true }); }
});
