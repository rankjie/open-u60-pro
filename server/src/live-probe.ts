import { randomUUID } from "node:crypto";
import { writeFileSync } from "node:fs";
import { privateFile } from "./apns";
import { object, secret } from "./protocol";

// Uses a one-time invitation and synthetic endpoints; never calls a real modem
// or registers a device push token. Only status is written to the terminal.
class Peer {
  socket: WebSocket;
  queue: Record<string, unknown>[] = [];
  constructor(address: string, token: string) {
    this.socket = new WebSocket(address.replace(/^https:/, "wss:") + "/v1/socket", { headers: { authorization: `Bearer ${token}` } });
    this.socket.addEventListener("message", event => this.queue.push(object(JSON.parse(String(event.data)))));
  }
  send(value: unknown) { this.socket.send(JSON.stringify(value)); }
  async next(type: string): Promise<Record<string, unknown>> {
    const deadline = Date.now() + 10000;
    while (Date.now() < deadline) {
      const index = this.queue.findIndex(value => value.type === type || value.type === "error");
      if (index >= 0) {
        const value = this.queue.splice(index, 1)[0];
        if (value.type === "error") throw new Error("Signaling rejected the synthetic operation");
        return value;
      }
      await Bun.sleep(20);
    }
    throw new Error("Signaling response timed out");
  }
  close() { this.socket.close(); }
}
async function main() {
  process.umask(0o077);
  const [address, invitationFile, relayFile] = Bun.argv.slice(2);
  const url = new URL(address);
  if (url.protocol !== "https:" || url.username || url.password || url.search || url.hash || !invitationFile || !relayFile) throw new Error("Usage: live-probe.ts https://server/openu60 invitation-file new-private-relay-file");
  const routerToken = secret(), phoneToken = secret();
  const request = async (path: string, token: string | undefined, method = "GET", body?: unknown) => {
    const response = await fetch(address.replace(/\/$/, "") + "/" + path, { method, signal: AbortSignal.timeout(10000),
      headers: { ...(token ? { authorization: `Bearer ${token}` } : {}), ...(body ? { "content-type": "application/json" } : {}) },
      body: body ? JSON.stringify(body) : undefined });
    if (!response.ok) throw new Error(`HTTP operation failed (${response.status})`);
    return object(await response.json());
  };
  await request("v1/enroll", undefined, "POST", { invitation: privateFile(invitationFile).trim(), deviceToken: routerToken, requestId: randomUUID() });
  const sockets: Peer[] = [];
  let callId: string | undefined, router: Peer | undefined;
  try {
    const pairing = await request("v1/pairings", routerToken, "POST", {});
    await request("v1/pair", undefined, "POST", { code: pairing.code, phoneToken, requestId: randomUUID() });
    router = new Peer(address, routerToken); sockets.push(router);
    const hello = await router.next("hello");
    if (!Array.isArray(hello.iceServers) || hello.iceServers.length === 0) throw new Error("TURN configuration missing");
    writeFileSync(relayFile, JSON.stringify(hello.iceServers), { flag: "wx", mode: 0o600 });
    const phone = new Peer(address, phoneToken); sockets.push(phone); await phone.next("hello");
    callId = randomUUID(); const requestId = randomUUID();
    phone.send({ type: "command", requestId, callId, action: "dial", number: "+999000001" });
    const delivered = await router.next("command");
    if (delivered.requestId !== requestId) throw new Error("Command identity changed");
    const now = Math.floor(Date.now() / 1000);
    if (typeof delivered.expiresAt !== "number" || delivered.expiresAt <= now || delivered.expiresAt > now + 21) throw new Error("Command deadline missing or invalid");
    router.send({ type: "result", requestId, callId, ok: true });
    if ((await phone.next("result")).ok !== true) throw new Error("Command result failed");
    router.send({ type: "signal", callId, description: { type: "offer", sdp: "v=0\r\n" } });
    if ((await phone.next("signal")).callId !== callId) throw new Error("Media routing failed");
    const eventId = randomUUID();
    router.send({ type: "event", eventId, callId, sequence: 1, state: "ended", mediaReady: false,
      observedAt: Math.floor(Date.now() / 1000), reason: "synthetic_probe_complete" });
    if ((await router.next("event_ack")).eventId !== eventId) throw new Error("Event acknowledgement failed");
    callId = undefined;
    console.info("Public HTTPS, authenticated WSS, pairing, command/result, media signaling, and durable event acknowledgement passed.");
  } finally {
    if (callId && router?.socket.readyState === WebSocket.OPEN) {
      router.send({ type: "event", eventId: randomUUID(), callId, sequence: 2, state: "ended", mediaReady: false,
        observedAt: Math.floor(Date.now() / 1000), reason: "synthetic_probe_cleanup" });
      await router.next("event_ack");
    }
    for (const socket of sockets) socket.close();
    await request("v1/router", routerToken, "DELETE");
  }
}
main().catch(error => { console.error("Live probe failed", error instanceof Error ? error.name : "unknown"); process.exitCode = 1; });
