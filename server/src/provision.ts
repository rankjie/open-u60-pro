import { chownSync, closeSync, existsSync, fsyncSync, mkdirSync, mkdtempSync, openSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { randomBytes } from "node:crypto";
import { dirname, join } from "node:path";

process.umask(0o077);
const [directory, publicURL, publicIP, privateIP, ...apnsArgs] = Bun.argv.slice(2);
if (!directory?.startsWith("/") || !publicURL || !publicIP || !privateIP) throw new Error("Usage: bun src/provision.ts /absolute/config-directory https://public-host/openu60 public-ip private-relay-ip");
const address = new URL(publicURL);
if (address.protocol !== "https:" || address.username || address.password || address.search || address.hash) throw new Error("An HTTPS public URL is required");
for (const ip of [publicIP, privateIP]) if (!/^(?:\d{1,3}\.){3}\d{1,3}$/.test(ip) || ip.split(".").some(value => Number(value) > 255)) throw new Error("Valid IPv4 addresses are required");
if (existsSync(directory)) throw new Error("Existing configuration must be edited explicitly; refusing to replace credentials");
const config: { hostname: string; port: number; database: string; publicURL: string;
  turn: { urls: string[]; secretFile: string }; apns?: { keyFile: string; teamId: string; keyId: string; bundleId: string } } = {
  hostname: "127.0.0.1", port: 46170, database: "/var/lib/openu60-calling/calling.sqlite",
  publicURL, turn: { urls: [`turn:${address.hostname}:3478?transport=udp`, `turn:${address.hostname}:3478?transport=tcp`],
    secretFile: join(directory, "turn-secret.private") } };
if (apnsArgs.length) {
  const [keyFile, teamId, keyId, bundleId] = apnsArgs;
  if (apnsArgs.length !== 4 || !keyFile.startsWith("/") || !/^[A-Z0-9]{10}$/.test(teamId)
    || !/^[A-Z0-9]{10}$/.test(keyId) || !/^[A-Za-z0-9.-]+$/.test(bundleId)) throw new Error("Invalid APNs metadata");
  config.apns = { keyFile, teamId, keyId, bundleId };
}
const secret = randomBytes(32).toString("base64url");
const turn = ["listening-port=3478", "listening-ip=0.0.0.0", `relay-ip=${privateIP}`, `external-ip=${publicIP}/${privateIP}`,
  "min-port=49160", "max-port=49200", "fingerprint", "use-auth-secret", `static-auth-secret=${secret}`, "realm=openu60",
  "no-tls", "no-dtls", "no-cli", "no-multicast-peers", "no-rfc5780", "no-stun-backward-compatibility",
  "total-quota=32", "user-quota=4", "max-bps=128000", "stale-nonce=600", "log-file=stdout", "simple-log",
  "denied-peer-ip=0.0.0.0-0.255.255.255", "denied-peer-ip=10.0.0.0-10.255.255.255", "denied-peer-ip=127.0.0.0-127.255.255.255",
  "denied-peer-ip=169.254.0.0-169.254.255.255", "denied-peer-ip=172.16.0.0-172.31.255.255", "denied-peer-ip=192.168.0.0-192.168.255.255",
  "denied-peer-ip=::1", "denied-peer-ip=fc00::-fdff:ffff:ffff:ffff:ffff:ffff:ffff:ffff", "denied-peer-ip=fe80::-febf:ffff:ffff:ffff:ffff:ffff:ffff:ffff"].join("\n") + "\n";
mkdirSync(dirname(directory), { recursive: true, mode: 0o700 });
const staging = mkdtempSync(join(dirname(directory), ".openu60-provision-"));
try {
  for (const [name, content] of [["turn-secret.private", secret + "\n"],
    ["calling-server.private.json", JSON.stringify(config, null, 2) + "\n"], ["coturn.private.conf", turn]]) {
    const file = openSync(join(staging, name), "wx", 0o600);
    try { writeFileSync(file, content); fsyncSync(file); } finally { closeSync(file); }
    if (process.getuid?.() === 0) chownSync(join(staging, name), 65532, 65532);
  }
  if (process.getuid?.() === 0) chownSync(staging, 65532, 65532);
  const sync = (path: string) => { const file = openSync(path, "r"); try { fsyncSync(file); } finally { closeSync(file); } };
  sync(staging);
  renameSync(staging, directory);
  sync(dirname(directory));
} finally { if (existsSync(staging)) rmSync(staging, { recursive: true }); }
console.info("Created private calling-server and TURN configuration. Existing files were not replaced.");
