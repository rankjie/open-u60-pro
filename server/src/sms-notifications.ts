import type { PushProvider } from "./apns";
import { Fault, hash, text, uuid, type Endpoint } from "./protocol";
import type { Store } from "./store";

interface Event {
  router_id: string; event_id: string; phone_id: string; message_id: string; fingerprint: string; payload: string | null; received_at: number;
  status: string; attempts: number;
}
export class SMSNotifications {
  private pushing = new Set<string>();
  private maintaining = false;
  constructor(private readonly store: Store, private readonly push?: PushProvider) {
    store.run("UPDATE sms_events SET status='pending' WHERE status='inflight'");
  }
  token(phone: Endpoint, body: Record<string, unknown>) {
    if (phone.role !== "phone") throw new Fault(403, "phone_required");
    const token = text(body.token, 512), environment = body.environment;
    if (!/^[a-f0-9]{64,512}$/i.test(token) || token.length % 2) throw new Fault(400, "invalid_push_token");
    if (environment !== "sandbox" && environment !== "production") throw new Fault(400, "invalid_push_environment");
    this.store.run("INSERT INTO notification_tokens(endpoint_id,token,environment) VALUES(?,?,?) ON CONFLICT(endpoint_id) DO UPDATE SET token=excluded.token,environment=excluded.environment,disabled=0",
      phone.id, token.toLowerCase(), environment);
  }
  remove(phone: Endpoint) {
    if (phone.role !== "phone") throw new Fault(403, "phone_required");
    this.store.run("DELETE FROM notification_tokens WHERE endpoint_id=?", phone.id);
  }
  accept(router: Endpoint, body: Record<string, unknown>): Event {
    if (router.role !== "router") throw new Fault(403, "router_required");
    const id = uuid(body.eventId), sender = text(body.sender, 128), messageId = text(body.messageId, 32);
    if (!/^\d{1,20}$/.test(messageId) || typeof body.content !== "string" || body.content.length > 87384
      || Buffer.from(body.content, "base64").toString("base64") !== body.content) throw new Fault(400, "invalid_sms_content");
    const bytes = Buffer.from(body.content, "base64");
    if (bytes.length > 65536) throw new Fault(400, "sms_content_too_large");
    let content: string;
    try { content = new TextDecoder("utf-8", { fatal: true }).decode(bytes); }
    catch { throw new Fault(400, "invalid_sms_encoding"); }
    const payload = JSON.stringify({ sender, text: content, messageId }), fingerprint = hash(payload);
    return this.store.transaction(() => {
      const old = this.store.one<Event>("SELECT * FROM sms_events WHERE router_id=? AND event_id=?", router.id, id);
      if (old) {
        if (old.fingerprint !== fingerprint) throw new Fault(409, "sms_event_conflict");
        return old;
      }
      const phone = this.store.one<Endpoint>("SELECT * FROM endpoints WHERE router_id=? AND role='phone' AND revoked=0", router.id);
      if (!phone) throw new Fault(409, "no_paired_phone");
      this.store.run("INSERT INTO sms_events(router_id,event_id,phone_id,message_id,fingerprint,payload,received_at,status,next_attempt) VALUES(?,?,?,?,?,?,?,'pending',?)",
        router.id, id, phone.id, messageId, fingerprint, payload, this.store.now(), this.store.now());
      return this.store.one<Event>("SELECT * FROM sms_events WHERE router_id=? AND event_id=?", router.id, id)!;
    });
  }
  async tick() {
    if (this.maintaining) return;
    this.maintaining = true;
    try {
    this.store.run("UPDATE sms_events SET status='expired',payload=NULL WHERE status='pending' AND (received_at<=? OR attempts>=12)", this.store.now() - 86400);
    this.store.run("UPDATE sms_events SET status='cancelled',payload=NULL WHERE status='pending' AND phone_id IN (SELECT id FROM endpoints WHERE revoked=1)");
    const events = this.store.all<Event>("SELECT sms_events.* FROM sms_events JOIN notification_tokens ON notification_tokens.endpoint_id=sms_events.phone_id JOIN endpoints ON endpoints.id=sms_events.phone_id WHERE sms_events.status='pending' AND next_attempt<=? AND disabled=0 AND revoked=0 ORDER BY received_at LIMIT 32", this.store.now());
    for (let start = 0; start < events.length; start += 4) {
      const results = await Promise.allSettled(events.slice(start, start + 4).map(event => this.deliver(event)));
      for (const result of results) if (result.status === "rejected") console.error("sms_notification_maintenance_failed");
    }
    } finally { this.maintaining = false; }
  }
  async deliver(event: Event) {
    const key = `${event.router_id}:${event.event_id}`;
    if (!this.push || this.pushing.has(key) || this.pushing.size >= 4) return;
    if (event.received_at <= this.store.now() - 86400 || event.attempts >= 12) {
      this.store.run("UPDATE sms_events SET status='expired',payload=NULL WHERE router_id=? AND event_id=? AND status='pending'", event.router_id, event.event_id);
      return;
    }
    const phone = this.store.one<{ token: string; environment: "sandbox" | "production" }>(
      "SELECT notification_tokens.* FROM notification_tokens JOIN endpoints ON endpoints.id=endpoint_id WHERE endpoint_id=? AND disabled=0 AND revoked=0", event.phone_id);
    if (!phone || event.status !== "pending") return;
    if (event.payload === null) throw new Error("Pending SMS notification has no payload");
    const claimed = this.store.run("UPDATE sms_events SET status='inflight',attempts=attempts+1 WHERE router_id=? AND event_id=? AND status='pending'",
      event.router_id, event.event_id);
    if (!claimed.changes) return;
    this.pushing.add(key);
    try {
      const outcome = await this.push.sendSMS(phone.token, phone.environment,
        { id: event.event_id, routerId: event.router_id, expiresAt: event.received_at + 86400, ...JSON.parse(event.payload) });
      this.store.run("UPDATE sms_events SET status=?,last_error=?,next_attempt=?,payload=? WHERE router_id=? AND event_id=? AND status='inflight'",
        outcome.kind === "accepted" ? "accepted" : outcome.kind === "reject" ? "rejected" : "pending",
        outcome.kind === "accepted" ? null : outcome.code,
        this.store.now() + Math.min(3600, 2 ** (event.attempts + 1)), outcome.kind === "retry" ? event.payload : null, event.router_id, event.event_id);
      if (outcome.kind === "reject" && ["BadDeviceToken", "Unregistered", "DeviceTokenNotForTopic"].includes(outcome.code)) {
        this.store.run("UPDATE notification_tokens SET disabled=1 WHERE endpoint_id=? AND token=?", event.phone_id, phone.token);
      }
    } catch (error) {
      this.store.run("UPDATE sms_events SET status='pending',last_error='provider_failure',next_attempt=? WHERE router_id=? AND event_id=? AND status='inflight'",
        this.store.now() + 30, event.router_id, event.event_id);
      console.error("sms_push_provider_failed", error instanceof Error ? error.name : "unknown");
    } finally { this.pushing.delete(key); }
  }
}
