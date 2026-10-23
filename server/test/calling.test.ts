import { afterEach, describe, expect, test } from "bun:test";
import { createECDH, generateKeyPairSync, randomUUID, verify } from "node:crypto";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { createServer, type ServerHttp2Stream } from "node:http2";
import { join } from "node:path";
import { APNs, missedCallPushRequest, smsPushRequests, type PushProvider, type PushOutcome } from "../src/apns";
import { Fault, secret, snapshot, type Endpoint } from "../src/protocol";
import { Store } from "../src/store";
import { CallingService } from "../src/service";
import { callAdmission } from "../src/call-admission";
import { hash } from "../src/protocol";

const resources: Array<() => void> = [];
afterEach(() => { for (const close of resources.splice(0).reverse()) close(); });

function fixture(push?: PushProvider) {
  const directory = mkdtempSync(join(tmpdir(), "openu60-synthetic-test-"));
  let clock = 1800000000;
  const store = new Store(join(directory, "test.sqlite"), () => clock);
  const service = new CallingService({ store, port: 0, maintenance: false, push,
    turn: { urls: ["turn:turn.example.invalid:3478?transport=udp"], secret: "synthetic-test-turn-secret-not-a-live-credential" } });
  resources.push(() => { service.stop(); store.close(); rmSync(directory, { recursive: true }); });
  const routerToken = secret();
  const router = store.enroll({ invitation: store.invite(), requestId: randomUUID(), deviceToken: routerToken });
  const phoneToken = secret();
  const phone = store.pair({ code: store.pairing(router).code, requestId: randomUUID(), phoneToken });
  return { store, service, router, phone, routerToken, phoneToken,
    url: `http://127.0.0.1:${service.server.port}`, advance: (seconds: number) => { clock += seconds; } };
}

describe("call device attribution and connected time", () => {
  test("an outgoing call reports when the callee's phone rings, and only while dialing", () => {
    const f = fixture(), callId = randomUUID();
    f.store.command(f.phone, { requestId: randomUUID(), callId, action: "dial", number: "+12345" });
    const event = (sequence: number, state: string, extra: Record<string, unknown> = {}) => f.store.event(f.router,
      { eventId: randomUUID(), callId, sequence, observedAt: 1800000000, mediaReady: state === "active", state, ...extra });
    expect(snapshot(f.store.call(callId)).alerting).toBe(false);
    expect(snapshot(event(1, "dialing", { alerting: true })).alerting).toBe(true);
    expect(() => event(2, "active", { alerting: true })).toThrow("invalid_alerting");
    expect(() => event(2, "dialing", { alerting: "yes" })).toThrow("invalid_alerting");
    const active = snapshot(event(2, "active"));
    expect(active.state).toBe("active");
    expect(active.alerting).toBe(false);
  });
  test("dial captures the authenticated phone and preserves the first connected time", () => {
    const f = fixture(), callId = randomUUID();
    const device = { name: "iPhone 16 Pro", model: "iPhone17,1", id: randomUUID() };
    const body = { requestId: randomUUID(), callId, action: "dial", number: "+12345", device };
    const operation = f.store.command(f.phone, body);
    expect(JSON.parse(operation.payload).phone).toEqual({ id: f.phone.id, name: device.name, model: device.model });
    const admitted = JSON.parse(operation.payload);
    expect(callAdmission(f.router.token_hash, f.phone.id, { ...admitted, phone: { ...admitted.phone, name: "Changed" } }))
      .not.toEqual(callAdmission(f.router.token_hash, f.phone.id, admitted));
    expect(snapshot(f.store.call(callId)).phone).toEqual({ id: f.phone.id, name: device.name, model: device.model });
    expect(snapshot(f.store.call(callId)).answeredAt).toBeNull();
    f.advance(5);
    f.store.event(f.router, { callId, eventId: randomUUID(), state: "active", sequence: 1, observedAt: f.store.now(), mediaReady: false });
    const connected = f.store.now(); f.advance(20);
    f.store.event(f.router, { callId, eventId: randomUUID(), state: "active", sequence: 2, observedAt: f.store.now(), mediaReady: true });
    expect(snapshot(f.store.call(callId)).answeredAt).toBe(connected);
    expect(f.store.command(f.phone, body).payload).toBe(operation.payload);
    expect(() => f.store.command(f.phone, { ...body, device: { ...device, name: "Another phone" } })).toThrow("operation_conflict");
  });
  test("the winning answer owns attribution, while legacy and missed calls remain unknown", () => {
    const f = fixture(), callId = randomUUID();
    const other = f.store.pair({ code: f.store.pairing(f.router).code, requestId: randomUUID(), phoneToken: secret() });
    f.store.event(f.router, { callId, eventId: randomUUID(), state: "ringing", sequence: 1, observedAt: f.store.now(), mediaReady: false, number: "+12345" });
    expect(snapshot(f.store.call(callId)).phone).toBeNull();
    const device = { name: "iPhone 17 Pro", model: "iPhone18,1" };
    f.store.command(other, { requestId: randomUUID(), callId, action: "answer", device });
    expect(snapshot(f.store.call(callId)).phone).toEqual({ id: other.id, ...device });
    expect(() => f.store.command(f.phone, { requestId: randomUUID(), callId, action: "answer", device: { name: "Loser", model: "iPhone17,1" } })).toThrow();
    expect(snapshot(f.store.call(callId)).phone).toEqual({ id: other.id, ...device });
    f.store.end(callId, "remote_hangup");
    const legacy = randomUUID();
    f.store.command(f.phone, { requestId: randomUUID(), callId: legacy, action: "dial", number: "12345" });
    expect(snapshot(f.store.call(legacy)).phone).toBeNull();
  });
  test("device metadata rejects blank names, control characters and invalid model identifiers", () => {
    for (const device of [{ name: " ", model: "iPhone17,1" }, { name: "iPhone\u0000other", model: "iPhone17,1" },
      { name: "iPhone\u007f", model: "iPhone17,1" }, { name: "iPhone", model: "bad\nmodel" },
      { name: "iPhone", model: "x".repeat(65) }, { name: "x".repeat(81), model: "iPhone17,1" }]) {
      const f = fixture();
      expect(() => f.store.command(f.phone, { requestId: randomUUID(), callId: randomUUID(), action: "dial", number: "12345", device })).toThrow();
      expect(f.store.currentCall(f.router.id)).toBeUndefined();
    }
  });
});

class Peer {
  readonly socket: WebSocket;
  private queue: any[] = [];
  private waiters: Array<{ predicate: (value: any) => boolean; resolve: (value: any) => void }> = [];
  constructor(url: string, token: string) {
    this.socket = new WebSocket(url.replace("http:", "ws:") + "/v1/socket", { headers: { authorization: `Bearer ${token}` } });
    resources.push(() => this.socket.close());
    this.socket.addEventListener("message", event => {
      const value = JSON.parse(String(event.data));
      const index = this.waiters.findIndex(waiter => waiter.predicate(value));
      if (index < 0) this.queue.push(value);
      else this.waiters.splice(index, 1)[0].resolve(value);
    });
  }
  send(value: unknown) { this.socket.send(JSON.stringify(value)); }
  queued(type: string) { return this.queue.some(value => value.type === type); }
  async next(type: string, predicate: (value: any) => boolean = () => true): Promise<any> {
    const matches = (v: any) => v.type === type && predicate(v);
    const index = this.queue.findIndex(matches);
    if (index >= 0) return this.queue.splice(index, 1)[0];
    return new Promise((resolve, reject) => {
      const timeout = setTimeout(() => { this.waiters = this.waiters.filter(w => w !== waiter); reject(new Error(`Timed out waiting for ${type}`)); }, 2000);
      const waiter = { predicate: matches, resolve: (value: any) => { clearTimeout(timeout); resolve(value); } };
      this.waiters.push(waiter);
    });
  }
}

describe("device string and encrypted password enrollment", () => {
  async function setup() {
    const f = fixture(), router = new Peer(f.url, f.routerToken), phone = new Peer(f.url, f.phoneToken);
    await router.next("hello"); await phone.next("hello");
    const identity = createECDH("prime256v1"); identity.generateKeys();
    const publicKey = identity.getPublicKey().toString("base64");
    router.send({ type:"peer_register", connectionKey:publicKey });
    await phone.next("presence", v => v.peerManagement === true);
    const body = { routerId:f.router.id, requestId:randomUUID(), phoneToken:secret(),
      enc:identity.getPublicKey().toString("base64"), ciphertext:Buffer.alloc(64, 41).toString("base64") };
    const connect = (value:unknown = body) => fetch(f.url + "/v1/connect", { method:"POST", headers:{"content-type":"application/json"}, body:JSON.stringify(value) });
    return { ...f, routerSocket:router, publicKey, body, connect };
  }
  test("only device approval admits a phone; retry preserves its authorization and other phones", async () => {
    const f = await setup();
    expect(await (await fetch(f.url + `/v1/connect/${f.router.id}`)).json()).toMatchObject({ routerId:f.router.id, publicKey:f.publicKey });
    const pending = f.connect();
    expect(await f.routerSocket.next("connect_request")).toEqual({ type:"connect_request", ...f.body });
    expect(f.store.phones(f.router.id)).toHaveLength(1);
    const ledger = f.store.one<Record<string,unknown>>("SELECT * FROM connection_attempts WHERE id=?", f.body.requestId)!;
    expect(Object.keys(ledger).sort()).toEqual(["error", "expires_at", "id", "router_id", "status", "token_hash"]);
    f.routerSocket.send({ type:"connect_result", requestId:f.body.requestId, phoneToken:f.body.phoneToken, ok:true });
    const response = await pending; expect(response.status).toBe(200);
    const identity = await response.json();
    expect(identity).toMatchObject({ routerId:f.router.id, role:"phone" });
    expect(f.store.phones(f.router.id)).toHaveLength(2);
    expect(await (await f.connect()).json()).toEqual(identity);
    expect(f.store.phones(f.router.id)).toHaveLength(2);
    f.service.stop();
    const restarted = new CallingService({ store:f.store, port:0, maintenance:false }); resources.push(() => restarted.stop());
    const retried = await fetch(`http://127.0.0.1:${restarted.server.port}/v1/connect`, {
      method:"POST", headers:{"content-type":"application/json"}, body:JSON.stringify(f.body) });
    expect(await retried.json()).toEqual(identity);
  });
  test("incorrect passwords and envelopes remain explicit failures without granting access", async () => {
    const f = await setup(), pending = f.connect(); await f.routerSocket.next("connect_request");
    f.routerSocket.send({ type:"connect_result", requestId:f.body.requestId, ok:false, error:"incorrect_router_password" });
    expect((await pending).status).toBe(401);
    expect(await (await f.connect()).json()).toEqual({error:"incorrect_router_password"});
    expect(f.store.phones(f.router.id)).toHaveLength(1);
    expect((await f.connect({...f.body, requestId:randomUUID(), enc:"invalid"})).status).toBe(400);
    expect((await f.connect({...f.body, phoneToken:secret()})).status).toBe(409);
  });
  test("another enrolled router cannot approve the connection and disconnect bounds the HTTP wait", async () => {
    const f = await setup();
    const token = secret(); f.store.enroll({invitation:f.store.invite(), requestId:randomUUID(), deviceToken:token});
    const foreign = new Peer(f.url,token); await foreign.next("hello");
    const pending = f.connect(); await f.routerSocket.next("connect_request");
    foreign.send({type:"connect_result", requestId:f.body.requestId, phoneToken:f.body.phoneToken, ok:true});
    expect((await foreign.next("error")).error).toBe("connection_not_found");
    f.routerSocket.socket.close();
    expect((await pending).status).toBe(503);
    expect(f.store.phones(f.router.id)).toHaveLength(1);
  });
  test("an unknown device is explicit and a concurrent call fails approval without leaving the phone waiting", async () => {
    const f = await setup();
    const missing = await fetch(f.url + `/v1/connect/${randomUUID()}`);
    expect(missing.status).toBe(404); expect(await missing.json()).toEqual({error:"router_not_found"});
    const pending = f.connect(); await f.routerSocket.next("connect_request");
    f.store.command(f.phone, {requestId:randomUUID(), callId:randomUUID(), action:"dial", number:"12345"});
    f.routerSocket.send({type:"connect_result", requestId:f.body.requestId, phoneToken:f.body.phoneToken, ok:true});
    const response = await pending;
    expect(response.status).toBe(409); expect(await response.json()).toEqual({error:"call_in_progress"});
    expect(f.store.phones(f.router.id)).toHaveLength(1);
  });
});

describe("management peer rendezvous", () => {
  async function connected() {
    const f = fixture(), router = new Peer(f.url, f.routerToken), phone = new Peer(f.url, f.phoneToken);
    await router.next("hello"); await phone.next("hello");
    router.send({ type: "peer_register" });
    expect((await phone.next("presence", v => v.peerManagement === true)).routerOnline).toBe(true);
    return { ...f, routerSocket: router, phoneSocket: phone };
  }
  test("authenticated peers exchange direct-only candidates independently of calls", async () => {
    const f = await connected(), id = randomUUID();
    f.phoneSocket.send({ type: "peer_open", sessionId: id });
    const left = await f.phoneSocket.next("peer_session"), right = await f.routerSocket.next("peer_session");
    expect(left).toEqual(right);
    expect(left).toMatchObject({ sessionId: id, routerId: f.router.id, phoneId: f.phone.id,
      iceServers: [{ urls: ["stun:turn.example.invalid:3478"], username: "", credential: "" }] });
    f.routerSocket.send({ type: "peer_signal", sessionId: id, description: { type: "offer", sdp: "v=0\r\n" } });
    expect((await f.phoneSocket.next("peer_signal")).description.type).toBe("offer");
    f.phoneSocket.send({ type: "peer_signal", sessionId: id, description: { type: "answer", sdp: "v=0\r\n" } });
    expect((await f.routerSocket.next("peer_signal")).description.type).toBe("answer");
    f.phoneSocket.send({ type: "peer_signal", sessionId: id, description: { type: "offer", sdp: "v=0\r\n" } });
    expect((await f.phoneSocket.next("error")).error).toBe("invalid_sdp_direction");
  });
  test("two paired phones have independent sessions and cannot signal each other's peer", async () => {
    const f = await connected(), token = secret();
    f.store.pair({ code: f.store.pairing(f.router).code, requestId: randomUUID(), phoneToken: token });
    const second = new Peer(f.url, token); await second.next("hello");
    const a = randomUUID(), b = randomUUID();
    f.phoneSocket.send({ type: "peer_open", sessionId: a });
    await f.phoneSocket.next("peer_session"); await f.routerSocket.next("peer_session");
    second.send({ type: "peer_open", sessionId: b });
    await second.next("peer_session"); await f.routerSocket.next("peer_session");
    second.send({ type: "peer_close", sessionId: a });
    expect((await second.next("error")).error).toBe("peer_session_not_found");
    f.phoneSocket.send({ type: "peer_close", sessionId: a });
    expect((await f.routerSocket.next("peer_closed")).sessionId).toBe(a);
    f.routerSocket.send({ type: "peer_signal", sessionId: b, description: { type: "offer", sdp: "v=0\r\n" } });
    expect((await second.next("peer_signal")).sessionId).toBe(b);
  });
  test.each(["expiry", "revocation", "disconnect"])("%s closes the admitted direct session", async reason => {
    const f = await connected(), id = randomUUID();
    f.phoneSocket.send({ type: "peer_open", sessionId: id });
    await f.phoneSocket.next("peer_session"); await f.routerSocket.next("peer_session");
    if (reason === "expiry") { f.advance(301); await f.service.tick(); }
    if (reason === "revocation") { f.store.run("UPDATE endpoints SET revoked=1 WHERE id=?", f.phone.id); await f.service.tick(); }
    if (reason === "disconnect") f.phoneSocket.socket.close();
    const closed = await f.routerSocket.next("peer_closed");
    expect(closed.sessionId).toBe(id);
    expect(closed.reason).toBe(reason === "expiry" ? "expired" : reason === "revocation" ? "pairing_revoked" : "peer_offline");
  });
});

describe("authenticated agent relay", () => {
  function relayRequest(f: ReturnType<typeof fixture>, overrides: Record<string, unknown> = {}) {
    return { requestId: randomUUID(), method: "GET", path: "/api/battery", body: "", expiresAt: f.store.now() + 20, ...overrides };
  }
  function relayFetch(f: ReturnType<typeof fixture>, body: unknown, token = f.phoneToken) {
    return fetch(f.url + "/v1/agent", { method: "POST", headers: { authorization: `Bearer ${token}`, "content-type": "application/json" }, body: JSON.stringify(body) });
  }
  test("reads traverse the authenticated router and preserve large JSON responses", async () => {
    const f = fixture(), router = new Peer(f.url, f.routerToken); await router.next("hello");
    const request = relayRequest(f), pending = relayFetch(f, request);
    const delivered = await router.next("agent_request");
    expect(delivered).toEqual({ type: "agent_request", ...request });
    const body = Buffer.from(JSON.stringify({ ok: true, data: "synthetic".repeat(14000) })).toString("base64");
    router.send({ type: "agent_result", requestId: request.requestId, status: 200, body });
    const response = await pending;
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ requestId: request.requestId, status: 200, body });
    expect(f.store.one("SELECT 1 FROM agent_operations WHERE id=?", request.requestId)).toBeUndefined();
  });
  test("SMS writes are immutable and their content is not persisted in the relay ledger", async () => {
    const f = fixture(), router = new Peer(f.url, f.routerToken); await router.next("hello");
    const content = "Synthetic SMS body for the isolated test";
    const request = relayRequest(f, { method: "POST", path: "/api/sms/send", body: Buffer.from(JSON.stringify({ message_body: content })).toString("base64") });
    const pending = relayFetch(f, request); await router.next("agent_request");
    const ledger = f.store.one<Record<string, unknown>>("SELECT * FROM agent_operations WHERE id=?", request.requestId)!;
    expect(Object.keys(ledger).sort()).toEqual(["expires_at", "fingerprint", "id", "phone_id", "router_id", "status"]);
    expect(JSON.stringify(ledger)).not.toContain(content);
    router.send({ type: "agent_result", requestId: request.requestId, status: 503, body: Buffer.from('{"ok":false,"error":"no_sim"}').toString("base64") });
    expect((await (await pending).json() as any).status).toBe(503);
    expect((await relayFetch(f, request)).status).toBe(409);
    const conflict = await relayFetch(f, { ...request, body: Buffer.from("different").toString("base64") });
    expect(await conflict.json()).toEqual({ error: "agent_request_conflict" });
  });
  test("disconnect after delivery reports an unknown outcome and never replays the write", async () => {
    const f = fixture(), router = new Peer(f.url, f.routerToken); await router.next("hello");
    const request = relayRequest(f, { method: "PUT", path: "/api/usb/powerbank", body: Buffer.from('{"state":0}').toString("base64") });
    const pending = relayFetch(f, request); await router.next("agent_request"); router.socket.close();
    const failed = await pending;
    expect(failed.status).toBe(504);
    expect(await failed.json()).toEqual({ error: "agent_outcome_unknown" });
    const replacement = new Peer(f.url, f.routerToken); await replacement.next("hello");
    expect(await (await relayFetch(f, request)).json()).toEqual({ error: "agent_outcome_unknown" });
    expect(f.store.one<any>("SELECT status FROM agent_operations WHERE id=?", request.requestId).status).toBe("unknown");
  });
  test("revoking the phone while a read is in progress withholds the response", async () => {
    const f = fixture(), router = new Peer(f.url, f.routerToken); await router.next("hello");
    const request = relayRequest(f), pending = relayFetch(f, request); await router.next("agent_request");
    f.store.revoke(f.router);
    router.send({ type: "agent_result", requestId: request.requestId, status: 200, body: Buffer.from('{"ok":true,"data":{}}').toString("base64") });
    const response = await pending;
    expect(response.status).toBe(401);
    expect(await response.json()).toEqual({ error: "pairing_revoked" });
  });
  test.each(["/api/auth/login", "/api/remote-calling/configure", "/api/lan/download", "/api/../auth/login", "/api//sms/send"])("rejects a non-relay endpoint %s", async path => {
    const f = fixture();
    const response = await relayFetch(f, relayRequest(f, { path }));
    expect(response.status).toBe(403);
  });
  test("router credentials cannot act as a phone and expired work never reaches a device", async () => {
    const f = fixture();
    expect((await relayFetch(f, relayRequest(f), f.routerToken)).status).toBe(403);
    expect((await relayFetch(f, relayRequest(f, { expiresAt: f.store.now() }))).status).toBe(408);
    expect((await relayFetch(f, relayRequest(f))).status).toBe(503);
  });
});

describe("local call command admission", () => {
  test("direct command admission has a stable cross-language authentication vector", () => {
    const command = {type:"command", requestId:"00000000-0000-4000-8000-000000000002", callId:"00000000-0000-4000-8000-000000000003",
      action:"dial", number:"+12345", expiresAt:1800000020};
    expect(callAdmission(hash("r".repeat(43)), "00000000-0000-4000-8000-000000000001", command)).toEqual({
      phoneId:"00000000-0000-4000-8000-000000000001", mac:"xjR1rpmlcyFjmmTUQyYGOPu_5XgMkvh9WnwhGGuv-co"});
    expect(() => callAdmission("invalid", "00000000-0000-4000-8000-000000000001", command)).toThrow("Invalid router credential verifier");
  });
  test("LAN admission and relay retry retain one canonical operation and expiry", async () => {
    const f = fixture(), router = new Peer(f.url, f.routerToken), phone = new Peer(f.url, f.phoneToken);
    await router.next("hello"); await phone.next("hello");
    const body = { requestId: randomUUID(), callId: randomUUID(), action: "dial", number: "12345" };
    const submit = (delivery: string, token = f.phoneToken) => fetch(f.url + "/v1/call-operation", {
      method: "POST", headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
      body: JSON.stringify({ ...body, delivery }),
    });
    const admitted = await submit("local"), local = await admitted.json() as any;
    expect(admitted.status).toBe(200); expect(local.status).toBe("pending");
    expect(local.command).toEqual({ type: "command", ...body, expiresAt: f.store.now() + 20 });
    expect(local.proof).toEqual(callAdmission(f.router.token_hash, f.phone.id, local.command));
    router.send({ type: "ping" }); await router.next("pong");
    expect(router.queued("command")).toBe(false);
    await phone.next("accepted");
    f.advance(3);
    const relayed = await (await submit("relay")).json() as any;
    expect(relayed.command).toEqual(local.command);
    expect(relayed.proof).toEqual(local.proof);
    expect(await router.next("command")).toEqual(local.command);
    router.send({ type: "result", requestId: body.requestId, callId: body.callId, ok: true });
    expect((await phone.next("result")).ok).toBe(true);
    const replay = await (await submit("relay")).json() as any;
    expect(replay.status).toBe("done"); expect(replay.ok).toBe(true);
    expect(f.store.one<any>("SELECT count(*) AS n FROM operations WHERE id=?", body.requestId).n).toBe(1);
    expect((await submit("local", f.routerToken)).status).toBe(403);
    expect((await submit("invalid")).status).toBe(400);
  });
});

describe("full SMS notifications", () => {
  test("APNs carries sender and complete text, splitting only at the real payload limit", () => {
    for (const text of ["Your code is 123456", "中文 🐼\n\\\"".repeat(1500), "\u0000".repeat(8000)]) {
      const event = { id: randomUUID(), routerId: randomUUID(), messageId: "42", sender: "Synthetic Sender", text, expiresAt: 1800086400 };
      const requests = smsPushRequests("com.beexio.openu60", event);
      expect(requests.map(request => request.payload.aps.alert.body).join("")).toBe(text);
      expect(new Set(requests.map(request => request.headers["apns-id"])).size).toBe(requests.length);
      for (const request of requests) {
        expect(Buffer.byteLength(JSON.stringify(request.payload))).toBeLessThanOrEqual(4096);
        expect(request.payload.aps.alert.title).toBe(event.sender);
        expect(request.headers["apns-push-type"]).toBe("alert");
        expect(request.headers["apns-topic"]).toBe("com.beexio.openu60");
        expect(request.payload.messageId).toBe("42");
      }
      expect(smsPushRequests("com.beexio.openu60", event)).toEqual(requests);
    }
  });
  test("a text in one part is labelled only by its sender; a split text numbers its parts", () => {
    const event = { id: randomUUID(), routerId: randomUUID(), messageId: "7", sender: "+31611145952", text: "aaaa", expiresAt: 1800086400 };
    expect(smsPushRequests("com.beexio.openu60", event).map(request => request.payload.aps.alert))
      .toEqual([{ title: "+31611145952", body: "aaaa" }]);
    const split = smsPushRequests("com.beexio.openu60", { ...event, text: "中".repeat(3000) });
    expect(split.map(request => (request.payload.aps.alert as { subtitle?: string }).subtitle)).toEqual(split.map((_, i) => `${i + 1}/${split.length}`));
    expect(split.length).toBeGreaterThan(1);
  });
  test("durable SMS admission acknowledges once and retries the full content without repeating VoIP", async () => {
    const sent: any[] = []; let attempt = 0;
    const f = fixture({ close() {}, async send() { throw new Error("SMS cannot use PushKit"); },
      async sendSMS(_token, environment, event) {
        sent.push({ environment, ...event });
        return ++attempt === 1 ? { kind: "retry", code: "apns_transport" } : { kind: "accepted", code: "accepted" };
      } });
    const register = await fetch(f.url + "/v1/notification-token", { method: "PUT",
      headers: { authorization: `Bearer ${f.phoneToken}`, "content-type": "application/json" },
      body: JSON.stringify({ token: "ab".repeat(32), environment: "sandbox" }) });
    expect(register.status).toBe(200);
    const router = new Peer(f.url, f.routerToken), phone = new Peer(f.url, f.phoneToken);
    await router.next("hello"); await phone.next("hello");
    const text = "Synthetic code 123456 中文 🐼", event = { type: "sms_event", eventId: randomUUID(), messageId: "42",
      sender: "Synthetic", content: Buffer.from(text).toString("base64") };
    router.send(event); await router.next("sms_ack"); await phone.next("sms_received");
    await new Promise(resolve => setTimeout(resolve, 5));
    expect(sent).toHaveLength(1); expect(sent[0].text).toBe(text);
    expect(f.store.one<any>("SELECT status FROM sms_events WHERE event_id=?", event.eventId).status).toBe("pending");
    f.advance(2); await f.service.tick();
    expect(sent).toHaveLength(2); expect(sent[1]).toEqual(sent[0]);
    const persisted = f.store.one<any>("SELECT * FROM sms_events WHERE event_id=?", event.eventId);
    expect(persisted.status).toBe("accepted"); expect(persisted.payload).toBeNull();
    router.send(event); await router.next("sms_ack");
    await f.service.tick(); expect(sent).toHaveLength(2);
    router.send({ ...event, content: Buffer.from("altered").toString("base64") });
    expect((await router.next("error")).error).toBe("sms_event_conflict");
    phone.send(event); expect((await phone.next("error")).error).toBe("router_required");
  });
  test("expired or revoked SMS outboxes clear content and never send to another pairing", async () => {
    let pushes = 0;
    const f = fixture({ close() {}, async send() { throw new Error("Unexpected call"); },
      async sendSMS() { pushes++; return { kind: "accepted", code: "accepted" }; } });
    const router = new Peer(f.url, f.routerToken); await router.next("hello");
    router.send({ type:"sms_event", eventId:randomUUID(), messageId:"1",sender:"Synthetic",content:Buffer.from("Synthetic text").toString("base64") });
    await router.next("sms_ack");
    f.advance(86400); await f.service.tick();
    expect(f.store.one<any>("SELECT status,payload FROM sms_events")).toEqual({ status:"expired",payload:null });
    f.store.revoke(f.router); await f.service.tick(); expect(pushes).toBe(0);
  });
});

describe("pairing and durable authorization", () => {
  test("an invitation is single use, but an identical enrollment retry recovers its identity", () => {
    const { store } = fixture();
    const invitation = store.invite(), requestId = randomUUID(), deviceToken = secret();
    const first = store.enroll({ invitation, requestId, deviceToken });
    expect(store.enroll({ invitation, requestId, deviceToken }).id).toBe(first.id);
    expect(() => store.enroll({ invitation, requestId: randomUUID(), deviceToken: secret() })).toThrow("invalid_invitation");
    expect(() => store.enroll({ invitation, requestId, deviceToken: secret() })).toThrow("enrollment_conflict");
  });
  test("expired pairing codes fail and another phone coexists with the first", () => {
    const { store, router, phone, phoneToken, advance } = fixture();
    const expired = store.pairing(router).code;
    advance(300);
    expect(() => store.pair({ code: expired, requestId: randomUUID(), phoneToken: secret() })).toThrow("invalid_pairing_code");
    const code = store.pairing(router).code, requestId = randomUUID(), token = secret();
    const replacement = store.pair({ code, requestId, phoneToken: token });
    expect(replacement.id).not.toBe(phone.id);
    expect(store.pair({ code, requestId, phoneToken: token }).id).toBe(replacement.id);
    expect(store.authenticate(`Bearer ${phoneToken}`).id).toBe(phone.id);
  });
  test("cross-router operations cannot inspect or mutate a call", () => {
    const { store, router, phone } = fixture();
    const callId = randomUUID();
    store.command(phone, { requestId: randomUUID(), callId, action: "dial", number: "+12345" });
    const other = store.enroll({ invitation: store.invite(), requestId: randomUUID(), deviceToken: secret() });
    expect(() => store.authorizeCall(other, callId)).toThrow("call_forbidden");
    expect(() => store.command(router, { requestId: randomUUID(), callId, action: "hangup" })).toThrow("phone_required");
    expect(() => store.result(phone, { requestId: randomUUID(), callId, ok: true })).toThrow("router_required");
  });
  test.each(["123;AT+CFUN=0", "1\n2", "", "++123", "x123"])("rejects a non-dialable number: %j", number => {
    const { store, phone } = fixture();
    expect(() => store.command(phone, { requestId: randomUUID(), callId: randomUUID(), action: "dial", number })).toThrow();
    expect(store.currentCall(phone.router_id)).toBeUndefined();
  });
  test("command IDs are immutable and survive reopening the database", () => {
    const { store, phone } = fixture();
    const body = { requestId: randomUUID(), callId: randomUUID(), action: "dial", number: "+12345" };
    const first = store.command(phone, body);
    expect(store.command(phone, body).id).toBe(first.id);
    expect(() => store.command(phone, { ...body, number: "+54321" })).toThrow("operation_conflict");
    const reopened = new Store(store.db.filename, store.now);
    try { expect(reopened.command(phone, body).id).toBe(first.id); }
    finally { reopened.close(); }
  });
});

describe("signaling over real WebSocket connections", () => {
  test("dial, offer/answer, modem activation and hangup preserve one call identity", async () => {
    const f = fixture(), router = new Peer(f.url, f.routerToken), phone = new Peer(f.url, f.phoneToken);
    const hello = await router.next("hello"); await phone.next("hello");
    expect(hello.iceServers[0].username).toContain(f.router.id);
    const callId = randomUUID(), requestId = randomUUID();
    phone.send({ type: "command", requestId, callId, action: "dial", number: "+12345" });
    const command = await router.next("command");
    expect(command.requestId).toBe(requestId);
    expect(command.expiresAt).toBe(f.store.now() + 20);
    f.advance(1);
    phone.send({ type: "command", requestId, callId, action: "dial", number: "+12345" });
    expect((await router.next("command")).expiresAt).toBe(command.expiresAt);
    await phone.next("accepted");
    router.send({ type: "signal", callId, description: { type: "offer", sdp: "v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 0\r\n" } });
    expect((await phone.next("signal")).description.type).toBe("offer");
    phone.send({ type: "signal", callId, description: { type: "answer", sdp: "v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 0\r\n" } });
    expect((await router.next("signal")).description.type).toBe("answer");
    router.send({ type: "result", requestId, callId, ok: true });
    expect((await phone.next("result")).ok).toBe(true);
    router.send({ type: "event", eventId: randomUUID(), callId, sequence: 1, observedAt: 1800000000, state: "active", mediaReady: true });
    const active = await phone.next("call", v => v.state === "active"); expect(active.mediaReady).toBe(true);
    const hangup = randomUUID();
    phone.send({ type: "command", requestId: hangup, callId, action: "hangup" });
    await router.next("command", v => v.action === "hangup");
    router.send({ type: "result", requestId: hangup, callId, ok: true });
    expect((await phone.next("call", v => v.state === "ended")).reason).toBe("local_hangup");
  });
  test("an offline router fails before a dial operation is persisted", async () => {
    const f = fixture(), phone = new Peer(f.url, f.phoneToken); await phone.next("hello");
    phone.send({ type: "command", requestId: randomUUID(), callId: randomUUID(), action: "dial", number: "123" });
    expect((await phone.next("error")).error).toBe("router_offline");
    expect(f.store.currentCall(f.router.id)).toBeUndefined();
  });
  test("pairing rejects arbitrary origins and throttles repeated wrong codes", async () => {
    const f = fixture();
    const request = (headers: Record<string, string> = {}) => fetch(f.url + "/v1/pair", { method: "POST", headers: { "content-type": "application/json", ...headers }, body: JSON.stringify({ code: "00000000", requestId: randomUUID(), phoneToken: secret() }) });
    expect((await request({ origin: "https://attacker.invalid" })).status).toBe(403);
    for (let i = 0; i < 10; i++) expect((await request()).status).toBe(403);
    expect((await request()).status).toBe(429);
  });
  test("expired commands fail explicitly, end setup, and cannot later be accepted", async () => {
    const f = fixture(), router = new Peer(f.url, f.routerToken), phone = new Peer(f.url, f.phoneToken);
    await router.next("hello"); await phone.next("hello");
    const callId = randomUUID(), requestId = randomUUID();
    phone.send({ type: "command", requestId, callId, action: "dial", number: "123" });
    await router.next("command"); f.advance(21); await f.service.tick();
    expect((await phone.next("result")).error).toBe("operation_timeout");
    router.send({ type: "result", requestId, callId, ok: true });
    expect(f.store.call(callId).state).toBe("ended");
  });
  test("revocation closes an already connected phone and invalidates subsequent HTTP access", async () => {
    const f = fixture(), phone = new Peer(f.url, f.phoneToken); await phone.next("hello");
    const closed = new Promise<number>(resolve => phone.socket.addEventListener("close", e => resolve(e.code)));
    const response = await fetch(f.url + "/v1/pairings", { method: "DELETE", headers: { authorization: `Bearer ${f.routerToken}` } });
    expect(response.status).toBe(200); expect(await closed).toBe(4001);
    expect((await fetch(f.url + "/v1/status", { headers: { authorization: `Bearer ${f.phoneToken}` } })).status).toBe(401);
  });
});

describe("incoming-call delivery and recovery", () => {
  test("an old ring replay ends without notifying the phone", async () => {
    let pushes = 0;
    const f = fixture({ close() {}, async sendSMS() { throw new Error("Unexpected SMS push"); }, async send() { pushes++; return { kind: "accepted", code: "accepted" }; } });
    f.store.pushToken(f.phone, { token: "cd".repeat(32), environment: "sandbox" });
    const call = f.store.event(f.router, { eventId: randomUUID(), callId: randomUUID(), sequence: 1,
      observedAt: f.store.now() - 46, state: "ringing", mediaReady: false });
    expect(call.state).toBe("ended"); expect(call.reason).toBe("stale_incoming_call");
    await f.service.tick(); expect(pushes).toBe(0);
  });
  test("a future modem clock fails before creating a call", () => {
    const f = fixture();
    expect(() => f.store.event(f.router, { eventId: randomUUID(), callId: randomUUID(), sequence: 1,
      observedAt: f.store.now() + 31, state: "ringing", mediaReady: false })).toThrow("invalid_event_time");
    expect(f.store.currentCall(f.router.id)).toBeUndefined();
  });
  test("presence and an explicit media request recover a paired call", async () => {
    const f = fixture(); const phone = new Peer(f.url, f.phoneToken);
    expect((await phone.next("hello")).routerOnline).toBe(false);
    const router = new Peer(f.url, f.routerToken); expect((await router.next("hello")).paired).toBe(true);
    expect((await phone.next("presence")).routerOnline).toBe(true);
    const callId = randomUUID();
    router.send({ type: "event", eventId: randomUUID(), callId, sequence: 1, observedAt: f.store.now(), state: "ringing", mediaReady: false });
    expect((await phone.next("call")).callId).toBe(callId);
    phone.send({ type: "command", requestId: randomUUID(), callId, action: "answer" });
    const answer = await router.next("command");
    router.send({ type: "result", requestId: answer.requestId, callId, ok: true });
    router.send({ type: "event", eventId: randomUUID(), callId, sequence: 2, observedAt: f.store.now(), state: "active", mediaReady: true });
    await phone.next("call", call => call.state === "active");
    await router.next("ice_servers"); f.advance(3601);
    phone.send({ type: "media_request", callId });
    expect((await router.next("ice_servers")).iceServers[0].username.split(":")[0]).toBe(String(f.store.now() + 3600));
    expect((await router.next("media_request")).callId).toBe(callId);
    router.socket.close(); expect((await phone.next("presence")).routerOnline).toBe(false);
  });
  test("invalidating a push token and forgetting pairing revoke access", async () => {
    const f = fixture(); const router = new Peer(f.url, f.routerToken); await router.next("hello");
    f.store.pushToken(f.phone, { token: "ef".repeat(32), environment: "sandbox" });
    const options = { method: "DELETE", headers: { authorization: `Bearer ${f.phoneToken}` } };
    expect((await fetch(f.url + "/v1/push-token", options)).status).toBe(200);
    expect(f.store.one<{ push_disabled: number }>("SELECT push_disabled FROM phones WHERE endpoint_id=?", f.phone.id)?.push_disabled).toBe(1);
    expect((await fetch(f.url + "/v1/phone", options)).status).toBe(200); await router.next("unpaired");
    expect(() => f.store.authenticate(`Bearer ${f.phoneToken}`)).toThrow("unauthorized");
  });
  test("a failed push retries durably, while a caller hangup cancels further attempts", async () => {
    const sent: string[] = [];
    const push: PushProvider = { close() {}, async sendSMS() { throw new Error("Unexpected SMS push"); }, async send(_token, _environment, call) { sent.push(call.id); return { kind: "retry", code: "apns_transport" }; } };
    const f = fixture(push);
    f.store.pushToken(f.phone, { token: "ab".repeat(32), environment: "sandbox" });
    const callId = randomUUID(), event = { eventId: randomUUID(), callId, sequence: 1, observedAt: 1800000000, mediaReady: false, state: "ringing", number: "123" };
    f.store.event(f.router, event); f.store.event(f.router, event);
    await f.service.tick(); expect(sent).toEqual([callId]);
    f.advance(2); await f.service.tick(); expect(sent).toEqual([callId, callId]);
    f.store.event(f.router, { ...event, eventId: randomUUID(), sequence: 2, state: "ended", reason: "remote_hangup" });
    f.advance(30); await f.service.tick(); expect(sent).toHaveLength(2);
  });
  test("stale or reordered modem events cannot resurrect an ended call", () => {
    const { store, router } = fixture(); const callId = randomUUID();
    store.event(router, { eventId: randomUUID(), callId, sequence: 1, observedAt: 1800000000, mediaReady: false, state: "ringing" });
    store.event(router, { eventId: randomUUID(), callId, sequence: 3, observedAt: 1800000000, mediaReady: false, state: "ended", reason: "remote_hangup" });
    const late = store.event(router, { eventId: randomUUID(), callId, sequence: 2, observedAt: 1800000000, state: "active", mediaReady: true });
    expect(late.state).toBe("ended"); expect(late.event_sequence).toBe(3);
  });
  test("invalid device tokens are disabled without retrying every ringing event", async () => {
    let attempts = 0;
    const push: PushProvider = { close() {}, async sendSMS() { throw new Error("Unexpected SMS push"); }, async send() { attempts++; return { kind: "reject", code: "BadDeviceToken" }; } };
    const f = fixture(push); f.store.pushToken(f.phone, { token: "ab".repeat(32), environment: "sandbox" });
    f.store.event(f.router, { eventId: randomUUID(), callId: randomUUID(), sequence: 1, observedAt: 1800000000, mediaReady: false, state: "ringing" });
    await f.service.tick(); f.advance(3); await f.service.tick(); expect(attempts).toBe(1);
    expect(f.store.one<{ push_disabled: number }>("SELECT push_disabled FROM phones WHERE endpoint_id=?", f.phone.id)?.push_disabled).toBe(1);
  });
  test("the APNs connection is opened before the first call and reused by its push", async () => {
    const { privateKey } = generateKeyPairSync("ec", { namedCurve: "prime256v1" });
    const sessions: string[] = [], paths: string[] = [];
    const server = createServer();
    server.on("session", session => { sessions.push("open"); session.on("close", () => sessions.push("closed")); });
    server.on("stream", (stream: ServerHttp2Stream, headers) => { paths.push(String(headers[":path"])); stream.respond({ ":status": 200 }); stream.end(); });
    await new Promise<void>(resolve => server.listen(0, "127.0.0.1", resolve));
    const address = `http://127.0.0.1:${(server.address() as { port: number }).port}`;
    const apns = new APNs("SYNTHETIC1", "SYNTHETIC2", "test.openu60", privateKey.export({ type: "pkcs8", format: "pem" }).toString(),
      { sandbox: address, production: "http://127.0.0.1:9" });
    apns.warm("sandbox");
    for (let i = 0; i < 100 && sessions.length === 0; i++) await Bun.sleep(10);
    expect(sessions).toEqual(["open"]);
    for (const id of [randomUUID(), randomUUID()]) {
      const outcome = await apns.send("ab".repeat(32), "sandbox", { id, routerId: randomUUID(), number: "12345", expiresAt: 1800000000 });
      expect(outcome.kind).toBe("accepted");
    }
    expect(sessions).toEqual(["open"]);
    expect(paths).toEqual([`/3/device/${"ab".repeat(32)}`, `/3/device/${"ab".repeat(32)}`]);
    apns.close();
    server.close();
  });
  test("a registered push token opens the APNs connection for its environment", async () => {
    const warmed: string[] = [];
    const push: PushProvider = { close() {}, warm(environment) { warmed.push(environment); },
      async sendSMS() { throw new Error("Unexpected SMS push"); }, async send() { throw new Error("Unexpected push"); } };
    const f = fixture(push);
    const response = await fetch(f.url + "/v1/push-token", { method: "PUT",
      headers: { authorization: `Bearer ${f.phoneToken}`, "content-type": "application/json" },
      body: JSON.stringify({ token: "cd".repeat(32), environment: "production" }) });
    expect(response.status).toBe(200);
    expect(warmed).toEqual(["production"]);
  });
  test("a restarted service reopens APNs for the environments its phones registered", () => {
    const f = fixture();
    f.store.pushToken(f.phone, { token: "ab".repeat(32), environment: "sandbox" });
    const disabled = f.store.pair({ code: f.store.pairing(f.router).code, requestId: randomUUID(), phoneToken: secret() });
    f.store.pushToken(disabled, { token: "cd".repeat(32), environment: "production" });
    f.store.run("UPDATE phones SET push_disabled=1 WHERE endpoint_id=?", disabled.id);
    f.service.stop();
    const warmed: string[] = [];
    const push: PushProvider = { close() {}, warm(environment) { warmed.push(environment); },
      async sendSMS() { throw new Error("Unexpected SMS push"); }, async send() { throw new Error("Unexpected push"); } };
    const restarted = new CallingService({ store: f.store, port: 0, maintenance: false, push });
    restarted.stop();
    expect(warmed).toEqual(["sandbox"]);
  });
  test("provider JWTs use ES256, the correct team/key IDs, and refresh after a clock rollback", () => {
    const { privateKey, publicKey } = generateKeyPairSync("ec", { namedCurve: "prime256v1" });
    const apns = new APNs("SYNTHETIC1", "SYNTHETIC2", "test.openu60", privateKey.export({ type: "pkcs8", format: "pem" }).toString());
    const jwt = apns.authorization(1800000000); const parts = jwt.split(".");
    expect(JSON.parse(Buffer.from(parts[0], "base64url").toString())).toEqual({ alg: "ES256", kid: "SYNTHETIC2" });
    expect(JSON.parse(Buffer.from(parts[1], "base64url").toString()).iss).toBe("SYNTHETIC1");
    expect(verify("sha256", Buffer.from(parts.slice(0, 2).join(".")), { key: publicKey, dsaEncoding: "ieee-p1363" }, Buffer.from(parts[2], "base64url"))).toBe(true);
    expect(apns.authorization(1800000010)).toBe(jwt);
    expect(apns.authorization(1799999990)).not.toBe(jwt);
    apns.close();
  });
});

describe("multiple paired phones", () => {
  function addPhone(f: ReturnType<typeof fixture>) {
    const token = secret();
    const endpoint = f.store.pair({ code: f.store.pairing(f.router).code, requestId: randomUUID(), phoneToken: token });
    return { endpoint, token };
  }
  function ring(f: ReturnType<typeof fixture>, callId = randomUUID()) {
    return f.store.event(f.router, { callId, eventId: randomUUID(), sequence: 1,
      state: "ringing", number: "12345", observedAt: f.store.now(), mediaReady: false });
  }
  test("adding a phone preserves existing sockets, push tokens and relay access", async () => {
    const f = fixture(), router = new Peer(f.url, f.routerToken), first = new Peer(f.url, f.phoneToken);
    await router.next("hello"); await first.next("hello");
    f.store.pushToken(f.phone, { token: "ab".repeat(32), environment: "sandbox" });
    const result = await fetch(f.url + "/v1/pair", { method: "POST", headers: { "content-type": "application/json" },
      body: JSON.stringify({ code: f.store.pairing(f.router).code, requestId: randomUUID(), phoneToken: secret() }) });
    expect(result.status).toBe(200);
    first.send({ type: "ping" }); await first.next("pong");
    expect(f.store.one<any>("SELECT push_disabled,push_token FROM phones WHERE endpoint_id=?", f.phone.id))
      .toEqual({ push_disabled: 0, push_token: "ab".repeat(32) });
    const requestId = randomUUID();
    const read = fetch(f.url + "/v1/agent", { method: "POST", headers: { authorization: `Bearer ${f.phoneToken}`, "content-type": "application/json" },
      body: JSON.stringify({ requestId, method: "GET", path: "/api/battery", body: "", expiresAt: f.store.now() + 20 }) });
    await router.next("agent_request");
    router.send({ type: "agent_result", requestId, status: 200, body: Buffer.from('{"ok":true,"data":{"capacity":87}}').toString("base64") });
    expect((await read).status).toBe(200);
  });
  test.each([0, 1])("all phones ring; contender %i claims audio once and ends the other phone", async winner => {
    const f = fixture(), other = addPhone(f), router = new Peer(f.url, f.routerToken);
    const phones = [new Peer(f.url, f.phoneToken), new Peer(f.url, other.token)];
    await router.next("hello"); await Promise.all(phones.map(phone => phone.next("hello")));
    const callId = randomUUID();
    router.send({ type: "event", callId, eventId: randomUUID(), sequence: 1, state: "ringing", number: "12345", observedAt: f.store.now(), mediaReady: false });
    await Promise.all(phones.map(async phone => expect((await phone.next("call")).state).toBe("ringing")));
    phones[1 - winner].send({ type: "media_request", callId });
    expect((await phones[1 - winner].next("error")).error).toBe("call_not_claimed");
    const answerIds = [randomUUID(), randomUUID()];
    phones[winner].send({ type: "command", requestId: answerIds[winner], callId, action: "answer" });
    await phones[winner].next("accepted");
    phones[1 - winner].send({ type: "command", requestId: answerIds[1 - winner], callId, action: "answer" });
    expect((await phones[1 - winner].next("error")).error).toBe("answered_elsewhere");
    const ended = await phones[1 - winner].next("call", call => call.state === "ended");
    expect(ended.reason).toBe("answered_elsewhere");
    const admitted = await router.next("command");
    expect(admitted.requestId).toBe(answerIds[winner]);
    expect(f.store.all("SELECT id FROM operations WHERE call_id=? AND action='answer'", callId)).toHaveLength(1);
    phones[winner].send({ type: "media_request", callId });
    await router.next("media_request");
    router.send({ type: "signal", callId, description: { type: "offer", sdp: "v=0\r\n" } });
    await phones[winner].next("signal");
    expect(phones[1 - winner].queued("signal")).toBe(false);
    phones[1 - winner].send({ type: "command", requestId: randomUUID(), callId, action: "hangup" });
    expect((await phones[1 - winner].next("error")).error).toBe("answered_elsewhere");
    const reconnected = new Peer(f.url, winner === 0 ? other.token : f.phoneToken);
    expect((await reconnected.next("hello")).calls[0]).toMatchObject({ state: "ended", reason: "answered_elsewhere" });
    router.send({ type: "result", requestId: admitted.requestId, callId, ok: true });
    expect((await phones[winner].next("result")).ok).toBe(true);
  });
  test("a ringing phone prepares audio before answering, and the answer keeps that connection", async () => {
    const f = fixture(), other = addPhone(f), router = new Peer(f.url, f.routerToken);
    const phones = [new Peer(f.url, f.phoneToken), new Peer(f.url, other.token)];
    await router.next("hello"); await Promise.all(phones.map(phone => phone.next("hello")));
    const callId = randomUUID();
    router.send({ type: "event", callId, eventId: randomUUID(), sequence: 1, state: "ringing", number: "12345", observedAt: f.store.now(), mediaReady: false });
    await Promise.all(phones.map(async phone => expect((await phone.next("call")).state).toBe("ringing")));
    // Only a prepared request is allowed while ringing; it names the phone for the router.
    phones[1].send({ type: "media_request", callId });
    expect((await phones[1].next("error")).error).toBe("call_not_claimed");
    phones[0].send({ type: "media_request", callId, prepare: true });
    expect(await router.next("media_request")).toMatchObject({ callId, phoneId: f.phone.id });
    router.send({ type: "signal", callId, description: { type: "offer", sdp: "v=0\r\n" } });
    expect((await phones[0].next("signal")).description.type).toBe("offer");
    phones[0].send({ type: "signal", callId, description: { type: "answer", sdp: "v=0\r\n" } });
    expect((await router.next("signal")).description.type).toBe("answer");
    phones[0].send({ type: "signal", callId, candidate: { candidate: "candidate:1 1 udp 1 192.0.2.1 9 typ host", sdpMid: "0", sdpMLineIndex: 0 } });
    expect((await router.next("signal")).candidate.sdpMid).toBe("0");
    expect(phones[1].queued("signal")).toBe(false);
    // The other phone cannot join the prepared connection.
    phones[1].send({ type: "signal", callId, description: { type: "answer", sdp: "v=0\r\n" } });
    expect((await phones[1].next("error")).error).toBe("call_not_claimed");
    phones[0].send({ type: "command", requestId: randomUUID(), callId, action: "answer" });
    await phones[0].next("accepted");
    expect((await router.next("command")).action).toBe("answer");
    router.send({ type: "signal", callId, candidate: { candidate: "candidate:2 1 udp 1 192.0.2.2 9 typ host", sdpMid: "0", sdpMLineIndex: 0 } });
    await phones[0].next("signal");
    // Once answered, preparing is over: a late prepare is refused.
    phones[0].send({ type: "media_request", callId, prepare: true });
    expect((await phones[0].next("error")).error).toBe("call_not_ringing");
  });
  test("every ringing phone keeps its own prepared connection, routed by phone", async () => {
    const f = fixture(), other = addPhone(f), stranger = addPhone(f), router = new Peer(f.url, f.routerToken);
    const phones = [new Peer(f.url, f.phoneToken), new Peer(f.url, other.token)];
    const ids = [f.phone.id, other.endpoint.id];
    await router.next("hello"); await Promise.all(phones.map(phone => phone.next("hello")));
    const callId = randomUUID();
    router.send({ type: "event", callId, eventId: randomUUID(), sequence: 1, state: "ringing", number: "12345", observedAt: f.store.now(), mediaReady: false });
    await Promise.all(phones.map(async phone => expect((await phone.next("call")).state).toBe("ringing")));
    for (const [index, phone] of phones.entries()) {
      phone.send({ type: "media_request", callId, prepare: true });
      expect(await router.next("media_request")).toMatchObject({ callId, phoneId: ids[index] });
    }
    // The router names the phone each offer is for; each phone's reply reaches the router stamped with it.
    for (const index of [1, 0]) {
      router.send({ type: "signal", callId, phoneId: ids[index], description: { type: "offer", sdp: "v=0\r\n" } });
      expect((await phones[index].next("signal")).description.type).toBe("offer");
      expect(phones[1 - index].queued("signal")).toBe(false);
    }
    expect(phones[0].queued("signal") || phones[1].queued("signal")).toBe(false);
    for (const index of [0, 1]) {
      phones[index].send({ type: "signal", callId, description: { type: "answer", sdp: "v=0\r\n" } });
      expect(await router.next("signal")).toMatchObject({ callId, phoneId: ids[index] });
    }
    // A phone that never prepared is not a target.
    router.send({ type: "signal", callId, phoneId: stranger.endpoint.id, description: { type: "offer", sdp: "v=0\r\n" } });
    expect((await router.next("error")).error).toBe("phone_not_preparing");
    // After the second phone answers, only it is a target.
    phones[1].send({ type: "command", requestId: randomUUID(), callId, action: "answer" });
    await phones[1].next("accepted");
    expect((await router.next("command")).action).toBe("answer");
    router.send({ type: "signal", callId, phoneId: ids[0], candidate: { candidate: "candidate:1 1 udp 1 192.0.2.1 9 typ host", sdpMid: "0", sdpMLineIndex: 0 } });
    expect((await router.next("error")).error).toBe("phone_not_preparing");
    router.send({ type: "signal", callId, phoneId: ids[1], candidate: { candidate: "candidate:2 1 udp 1 192.0.2.2 9 typ host", sdpMid: "0", sdpMLineIndex: 0 } });
    expect((await phones[1].next("signal")).candidate.sdpMid).toBe("0");
  });
  test("simultaneous HTTP answers persist one winner and one modem operation", async () => {
    const f = fixture(), other = addPhone(f), router = new Peer(f.url, f.routerToken); await router.next("hello");
    const call = ring(f);
    const results = await Promise.all([f.phoneToken, other.token].map(token => fetch(f.url + "/v1/call-operation", {
      method: "POST", headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
      body: JSON.stringify({ requestId: randomUUID(), callId: call.id, action: "answer", delivery: "relay" }),
    })));
    expect(results.map(response => response.status).sort()).toEqual([200, 409]);
    expect(f.store.all("SELECT id FROM operations WHERE call_id=?", call.id)).toHaveLength(1);
    expect(f.store.call(call.id).state).toBe("answering");
  });
  test("declining on one phone keeps the others ringing, and the last decline reaches the modem", () => {
    const f = fixture(), other = addPhone(f), call = ring(f);
    const first = f.store.command(f.phone, { requestId: randomUUID(), callId: call.id, action: "hangup" });
    expect(first.status).toBe("done");
    expect(f.store.phoneCall(f.store.call(call.id), other.endpoint)?.state).toBe("ringing");
    expect(f.store.phoneCall(f.store.call(call.id), f.phone)?.reason).toBe("declined_on_device");
    const last = f.store.command(other.endpoint, { requestId: randomUUID(), callId: call.id, action: "hangup" });
    expect(last.status).toBe("pending");
    f.store.result(f.router, { requestId: last.id, callId: call.id, ok: true });
    expect(f.store.call(call.id).state).toBe("ended");
  });
  test("incoming push delivery and retries belong to each phone independently", async () => {
    const attempts = new Map<string, number>();
    const f = fixture({ close() {}, async sendSMS() { throw new Error("Unexpected SMS"); }, async send(token) {
      const n = (attempts.get(token) ?? 0) + 1; attempts.set(token, n);
      return token.startsWith("ab") && n === 1 ? { kind: "retry", code: "apns_transport" } : { kind: "accepted", code: "accepted" };
    } });
    const other = addPhone(f), tokens = ["ab".repeat(32), "cd".repeat(32)];
    f.store.pushToken(f.phone, { token: tokens[0], environment: "sandbox" });
    f.store.pushToken(other.endpoint, { token: tokens[1], environment: "sandbox" });
    ring(f); await f.service.tick(); expect([...attempts.values()]).toEqual([1, 1]);
    f.advance(2); await f.service.tick();
    expect(attempts.get(tokens[0])).toBe(2); expect(attempts.get(tokens[1])).toBe(1);
  });
  test("full SMS fans out once per phone, with independent retries and no historical delivery to later pairings", async () => {
    const sent = new Map<string, string[]>();
    const f = fixture({ close() {}, async send() { throw new Error("Unexpected call"); }, async sendSMS(token, _, event) {
      const texts = sent.get(token) ?? []; texts.push(event.text); sent.set(token, texts);
      return token.startsWith("ab") && texts.length === 1 ? { kind: "retry", code: "apns_transport" } : { kind: "accepted", code: "accepted" };
    } });
    const other = addPhone(f), tokens = ["ab".repeat(32), "cd".repeat(32)];
    for (const [i, endpoint] of [f.phone, other.endpoint].entries()) {
      expect((await fetch(f.url + "/v1/notification-token", { method: "PUT", headers: { authorization: `Bearer ${i === 0 ? f.phoneToken : other.token}`, "content-type": "application/json" },
        body: JSON.stringify({ token: tokens[i], environment: "sandbox" }) })).status).toBe(200);
    }
    const router = new Peer(f.url, f.routerToken), first = new Peer(f.url, f.phoneToken), second = new Peer(f.url, other.token);
    await router.next("hello"); await first.next("hello"); await second.next("hello");
    const event = { type: "sms_event", eventId: randomUUID(), messageId: "7", sender: "Synthetic", content: Buffer.from("Full synthetic SMS 123456").toString("base64") };
    router.send(event); await router.next("sms_ack"); await first.next("sms_received"); await second.next("sms_received");
    await new Promise(resolve => setTimeout(resolve, 10));
    expect(sent.get(tokens[0])).toEqual(["Full synthetic SMS 123456"]);
    expect(sent.get(tokens[1])).toEqual(["Full synthetic SMS 123456"]);
    addPhone(f); router.send(event); await router.next("sms_ack");
    f.advance(2); await f.service.tick();
    expect(sent.get(tokens[0])).toHaveLength(2); expect(sent.get(tokens[1])).toHaveLength(1);
    expect(f.store.all("SELECT phone_id FROM sms_events WHERE event_id=?", event.eventId)).toHaveLength(2);
    expect(f.store.all<any>("SELECT payload FROM sms_events WHERE event_id=?", event.eventId).every(row => row.payload === null)).toBe(true);
  });
  test("a missed call alert names the caller and stays out of the call push topic", () => {
    const call = { id: randomUUID(), routerId: randomUUID(), number: "+31611145952", expiresAt: 1800086400 };
    const request = missedCallPushRequest("com.beexio.openu60", call);
    expect(request.payload.aps.alert).toEqual({ title: "+31611145952", body: "Missed call" });
    expect(request.payload).toMatchObject({ kind: "missed_call", callId: call.id, routerId: call.routerId });
    expect(request.headers).toMatchObject({ "apns-topic": "com.beexio.openu60", "apns-push-type": "alert", "apns-expiration": "1800086400" });
    expect(missedCallPushRequest("com.beexio.openu60", { ...call, number: "" }).payload.aps.alert.title).toBe("Unknown");
  });
  test("a call that rang out unanswered and undeclined is a missed call on every phone", async () => {
    const sent: Array<{ token: string; id: string; number: string }> = [];
    const f = fixture({ close() {}, async send() { return { kind: "accepted", code: "accepted" }; }, async sendSMS() { throw new Error("Unexpected SMS"); },
      async sendMissedCall(token, _, call) {
        sent.push({ token, id: call.id, number: call.number });
        return token.startsWith("ab") && sent.filter(item => item.token === token && item.id === call.id).length === 1
          ? { kind: "retry", code: "apns_transport" } : { kind: "accepted", code: "accepted" };
      } });
    const other = addPhone(f), tokens = ["ab".repeat(32), "cd".repeat(32)];
    for (const [i, endpoint] of [f.phone, other.endpoint].entries()) {
      f.store.run("INSERT INTO notification_tokens(endpoint_id,token,environment) VALUES(?,?,'sandbox')", endpoint.id, tokens[i]);
    }
    const router = new Peer(f.url, f.routerToken); await router.next("hello");
    const end = (callId: string, sequence: number, reason = "remote_hangup") =>
      f.store.event(f.router, { callId, eventId: randomUUID(), sequence, state: "ended", reason, observedAt: f.store.now(), mediaReady: false });

    // The caller gives up while every phone still rings: alerted at once, without waiting for maintenance.
    const missed = randomUUID();
    ring(f, missed);
    router.send({ type: "event", callId: missed, eventId: randomUUID(), sequence: 2, state: "ended", reason: "remote_hangup", observedAt: f.store.now(), mediaReady: false });
    await router.next("event_ack"); await new Promise(resolve => setTimeout(resolve, 10));
    expect(sent.map(item => [item.token, item.id, item.number])).toEqual([[tokens[0], missed, "12345"], [tokens[1], missed, "12345"]]);
    f.advance(2); await f.service.tick(); await f.service.tick();
    expect(sent.filter(item => item.id === missed).map(item => item.token)).toEqual([tokens[0], tokens[1], tokens[0]]);

    // Declined on one phone: the person saw it, so no phone reports it as missed.
    const declined = randomUUID(); ring(f, declined);
    f.store.command(f.phone, { requestId: randomUUID(), callId: declined, action: "hangup" });
    end(declined, 2);
    // Answered, then ended: not missed either.
    const answered = randomUUID(); ring(f, answered);
    f.store.command(other.endpoint, { requestId: randomUUID(), callId: answered, action: "answer" });
    f.store.event(f.router, { callId: answered, eventId: randomUUID(), sequence: 2, state: "active", observedAt: f.store.now(), mediaReady: true });
    end(answered, 3);
    await f.service.tick();
    expect(sent.some(item => item.id === declined || item.id === answered)).toBe(false);

    // Nobody touched it and the router never reported the end: the ring timeout makes it missed.
    const unknown = randomUUID();
    f.store.event(f.router, { callId: unknown, eventId: randomUUID(), sequence: 1, state: "ringing", observedAt: f.store.now(), mediaReady: false });
    f.advance(45); await f.service.tick();
    expect(sent.filter(item => item.id === unknown).map(item => [item.token, item.number])).toEqual([[tokens[0], ""], [tokens[1], ""]]);
  });
  test("forgetting one phone leaves another paired and the router monitoring messages", async () => {
    const f = fixture(), other = addPhone(f), router = new Peer(f.url, f.routerToken); await router.next("hello");
    expect((await fetch(f.url + "/v1/phone", { method: "DELETE", headers: { authorization: `Bearer ${f.phoneToken}` } })).status).toBe(200);
    await router.next("paired");
    expect(f.store.authenticate(`Bearer ${other.token}`).id).toBe(other.endpoint.id);
    expect(() => f.store.authenticate(`Bearer ${f.phoneToken}`)).toThrow("unauthorized");
    addPhone(f);
    expect(() => f.store.authenticate(`Bearer ${f.phoneToken}`)).toThrow("unauthorized");
  });
});

describe("multi-phone persistence upgrades", () => {
  test("legacy outbox deliveries and endpoint credentials survive composite-key migration", () => {
    const f = fixture();
    const operation = f.store.command(f.phone, { requestId: randomUUID(), callId: randomUUID(), action: "dial", number: "12345" });
    f.store.db.exec(`DROP TABLE push_outbox;
      CREATE TABLE push_outbox(call_id TEXT PRIMARY KEY REFERENCES calls(id),phone_id TEXT NOT NULL,status TEXT NOT NULL,
        attempts INTEGER NOT NULL DEFAULT 0,next_attempt INTEGER NOT NULL,last_error TEXT);
      DROP TABLE sms_events;
      CREATE TABLE sms_events(router_id TEXT NOT NULL,event_id TEXT NOT NULL,phone_id TEXT NOT NULL REFERENCES endpoints(id),
        message_id TEXT NOT NULL,fingerprint TEXT NOT NULL,payload TEXT,received_at INTEGER NOT NULL,status TEXT NOT NULL,
        attempts INTEGER NOT NULL DEFAULT 0,next_attempt INTEGER NOT NULL,last_error TEXT,PRIMARY KEY(router_id,event_id));`);
    f.store.run("INSERT INTO push_outbox VALUES(?,?,'pending',3,?,'apns_transport')", operation.call_id, f.phone.id, f.store.now());
    const eventId = randomUUID();
    f.store.run("INSERT INTO sms_events VALUES(?,?,?,'42','synthetic-fingerprint',?,?,'pending',2,?,'apns_transport')",
      f.router.id, eventId, f.phone.id, '{"text":"Synthetic pending SMS"}', f.store.now(), f.store.now());
    const endpoints = f.store.all("SELECT * FROM endpoints"), calls = f.store.all("SELECT * FROM calls");
    const push = f.store.all("SELECT * FROM push_outbox"), sms = f.store.all("SELECT * FROM sms_events");
    const migrated = new Store(f.store.db.filename, f.store.now);
    try {
      expect(migrated.all("SELECT * FROM endpoints")).toEqual(endpoints);
      expect(migrated.all("SELECT * FROM calls")).toEqual(calls);
      expect(migrated.all("SELECT * FROM push_outbox")).toEqual(push);
      expect(migrated.all("SELECT * FROM sms_events")).toEqual(sms);
      expect(migrated.all("PRAGMA foreign_key_check")).toEqual([]);
      expect(migrated.authenticate(`Bearer ${f.phoneToken}`).id).toBe(f.phone.id);
      const otherId = randomUUID();
      migrated.run("INSERT INTO endpoints(id,role,router_id,token_hash) VALUES(?,'phone',?,?)", otherId, f.router.id, "synthetic-other-token-hash");
      migrated.run("INSERT INTO push_outbox VALUES(?,?,'pending',0,?,NULL)", operation.call_id, otherId, f.store.now());
      migrated.run("INSERT INTO sms_events VALUES(?,?,?,'42','synthetic-fingerprint',?,?,'pending',0,?,NULL)",
        f.router.id, eventId, otherId, '{"text":"Synthetic pending SMS"}', f.store.now(), f.store.now());
      expect(migrated.all("SELECT phone_id FROM push_outbox")).toHaveLength(2);
      expect(migrated.all("SELECT phone_id FROM sms_events")).toHaveLength(2);
      const reopened = new Store(migrated.db.filename, f.store.now);
      try { expect(reopened.all("SELECT phone_id FROM sms_events")).toHaveLength(2); }
      finally { reopened.close(); }
    } finally { migrated.close(); }
  });
  test("restart preserves the answered phone and does not ring a losing or dismissed phone", () => {
    const f = fixture();
    const other = f.store.pair({ code: f.store.pairing(f.router).code, requestId: randomUUID(), phoneToken: secret() });
    const call = f.store.event(f.router, { eventId: randomUUID(), callId: randomUUID(), sequence: 1,
      observedAt: f.store.now(), state: "ringing", mediaReady: false });
    const answer = { requestId: randomUUID(), callId: call.id, action: "answer" };
    const accepted = f.store.command(other, answer);
    const reopened = new Store(f.store.db.filename, f.store.now);
    try {
      const current = reopened.call(call.id);
      expect(reopened.phoneCall(current, f.phone)).toMatchObject({ state: "ended", reason: "answered_elsewhere" });
      expect(reopened.phoneCall(current, other)).toMatchObject({ state: "answering", phone_id: other.id });
      expect(reopened.command(other, answer).id).toBe(accepted.id);
      expect(() => reopened.command(f.phone, answer)).toThrow("call_forbidden");
      expect(reopened.all("SELECT * FROM operations WHERE call_id=?", call.id)).toHaveLength(1);
    } finally { reopened.close(); }
  });
});
