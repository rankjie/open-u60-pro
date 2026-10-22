import { afterEach, expect, test } from "bun:test";
import { randomUUID } from "node:crypto";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { configuration } from "../src/config";
import { secret } from "../src/protocol";
import { CallingService } from "../src/service";
import { Store } from "../src/store";

const cleanup: Array<() => void> = [];
afterEach(() => { for (const close of cleanup.splice(0).reverse()) close(); });
const pin = "A".repeat(43);

function config(doors: unknown) {
  const directory = mkdtempSync(join(tmpdir(), "openu60-synthetic-doors-"));
  cleanup.push(() => rmSync(directory, { recursive: true }));
  const file = join(directory, "config.json");
  writeFileSync(file, JSON.stringify({ hostname: "127.0.0.1", port: 46170, database: "/tmp/x.sqlite",
    publicURL: "https://relay.example.invalid/openu60", ...(doors === undefined ? {} : { doors }) }), { mode: 0o600 });
  return () => configuration(file);
}

test("doors are optional and validated as quic addresses with a pin", () => {
  expect(config(undefined)().doors).toEqual([]);
  const doors = [{ address: `quic://114.55.246.231:47853#${pin}`, label: "Hangzhou" },
    { address: `quic://[2001:db8::1]:9000#${pin}`, label: "IPv6" }, { address: `quic://door.example:443/#${pin}`, label: "Named" }];
  expect(config(doors)().doors).toEqual(doors);
  for (const bad of [
    [{ address: `https://door.example#${pin}`, label: "x" }],
    [{ address: `quic://door.example#${pin}`, label: "x" }],
    [{ address: `quic://door.example:47853`, label: "x" }],
    [{ address: `quic://door.example:47853#short`, label: "x" }],
    [{ address: `quic://user@door.example:47853#${pin}`, label: "x" }],
    [{ address: `quic://door.example:47853#${pin}`, label: "" }],
    [{ address: `quic://door.example:47853#${pin}`, label: "x".repeat(33) }],
    Array.from({ length: 9 }, () => ({ address: `quic://door.example:1#${pin}`, label: "x" })),
    "not a list",
  ]) expect(config(bad)).toThrow();
});

test("routers and phones learn the doors in hello and status", async () => {
  const directory = mkdtempSync(join(tmpdir(), "openu60-synthetic-doors-"));
  const store = new Store(join(directory, "test.sqlite"));
  const doors = [{ address: `quic://114.55.246.231:47853#${pin}`, label: "Hangzhou" }];
  const service = new CallingService({ store, port: 0, maintenance: false, doors });
  cleanup.push(() => { service.stop(); store.close(); rmSync(directory, { recursive: true }); });
  const routerToken = secret();
  const router = store.enroll({ invitation: store.invite(), requestId: randomUUID(), deviceToken: routerToken });
  const phoneToken = secret();
  store.pair({ code: store.pairing(router).code, requestId: randomUUID(), phoneToken });
  const url = `http://127.0.0.1:${service.server.port}`;
  const hello = await new Promise<Record<string, unknown>>((resolve, reject) => {
    const socket = new WebSocket(url.replace("http", "ws") + "/v1/socket", { headers: { authorization: `Bearer ${phoneToken}` } } as never);
    socket.onmessage = event => { const value = JSON.parse(String(event.data)); if (value.type === "hello") { resolve(value); socket.close(); } };
    socket.onerror = reject;
  });
  expect(hello.doors).toEqual(doors);
  const status = await (await fetch(url + "/v1/status", { headers: { authorization: `Bearer ${phoneToken}` } })).json();
  expect(status.doors).toEqual(doors);
});
