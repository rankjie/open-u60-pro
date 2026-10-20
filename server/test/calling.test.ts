import { afterEach, describe, expect, test } from "bun:test";
import { generateKeyPairSync, randomUUID, verify } from "node:crypto";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { APNs, smsPushRequests, type PushProvider, type PushOutcome } from "../src/apns";
import { Fault, secret, snapshot, type Endpoint } from "../src/protocol";
import { Store } from "../src/store";
import { CallingService } from "../src/service";

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
    router.send({ type: "ping" }); await router.next("pong");
    expect(router.queued("command")).toBe(false);
    await phone.next("accepted");
    f.advance(3);
    const relayed = await (await submit("relay")).json() as any;
    expect(relayed.command).toEqual(local.command);
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
  test("expired pairing codes fail and re-pairing revokes the previous phone", () => {
    const { store, router, phone, phoneToken, advance } = fixture();
    const expired = store.pairing(router).code;
    advance(300);
    expect(() => store.pair({ code: expired, requestId: randomUUID(), phoneToken: secret() })).toThrow("invalid_pairing_code");
    const code = store.pairing(router).code, requestId = randomUUID(), token = secret();
    const replacement = store.pair({ code, requestId, phoneToken: token });
    expect(replacement.id).not.toBe(phone.id);
    expect(store.pair({ code, requestId, phoneToken: token }).id).toBe(replacement.id);
    expect(() => store.authenticate(`Bearer ${phoneToken}`)).toThrow("unauthorized");
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
    router.send({ type: "event", eventId: randomUUID(), callId, sequence: 2, observedAt: f.store.now(), state: "active", mediaReady: true });
    await phone.next("call"); f.advance(3601);
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
