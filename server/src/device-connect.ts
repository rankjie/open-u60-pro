import { Fault, hash, object, text, token, uuid, type Endpoint } from "./protocol";
import type { Store } from "./store";

interface Attempt { id: string; router_id: string; token_hash: string; status: string; error: string | null; expires_at: number }
interface Waiting { router: string; timer: ReturnType<typeof setTimeout>; resolve: (endpoint: Endpoint) => void; reject: (error: Fault) => void }

/** The password envelope is opaque. Only the enrolled U60 can approve a new phone. */
export class DeviceConnect {
  private keys = new Map<string, string>();
  private waiting = new Map<string, Waiting>();
  constructor(private readonly store: Store, private readonly send: (id: string, value: unknown) => void) {
    store.db.exec(`CREATE TABLE IF NOT EXISTS connection_attempts(id TEXT PRIMARY KEY, router_id TEXT NOT NULL,
      token_hash TEXT NOT NULL, status TEXT NOT NULL, error TEXT, expires_at INTEGER NOT NULL);`);
  }
  register(router: Endpoint, value: unknown) {
    if (router.role !== "router") throw new Fault(403, "router_required");
    const key = this.bytes(value, 65, 65);
    if (Buffer.from(key, "base64")[0] !== 4) throw new Fault(400, "invalid_connection_key");
    this.keys.set(router.id, key);
  }
  lookup(id: string) {
    let router: Endpoint;
    try { router = this.store.endpoint(uuid(id)); }
    catch (error) {
      if (error instanceof Fault && error.status === 401) throw new Fault(404, "router_not_found");
      throw error;
    }
    if (router.role !== "router") throw new Fault(404, "router_not_found");
    const key = this.keys.get(uuid(id));
    if (!key) throw new Fault(503, "router_offline");
    return { routerId: id, publicKey: key, serverTime: this.store.now() };
  }
  async request(input: unknown) {
    const body = object(input), id = uuid(body.requestId), router = uuid(body.routerId), phoneToken = token(body.phoneToken);
    const previous = this.store.one<Endpoint>("SELECT * FROM endpoints WHERE request_id=?", id);
    if (previous) {
      if (previous.revoked || previous.role !== "phone" || previous.router_id !== router || previous.token_hash !== hash(phoneToken)) throw new Fault(409, "connection_conflict");
      return previous;
    }
    this.lookup(router);
    if (this.store.currentCall(router)) throw new Fault(409, "call_in_progress");
    const enc = this.bytes(body.enc, 65, 65), ciphertext = this.bytes(body.ciphertext, 32, 2048);
    if (this.waiting.has(id)) throw new Fault(409, "connection_in_progress");
    if (this.waiting.size >= 256 || [...this.waiting.values()].filter(v => v.router === router).length >= 4) throw new Fault(429, "connection_busy");
    this.store.transaction(() => {
      this.store.run("DELETE FROM connection_attempts WHERE expires_at<=?", this.store.now());
      const attempt = this.store.one<Attempt>("SELECT * FROM connection_attempts WHERE id=?", id);
      if (attempt) {
        if (attempt.router_id !== router || attempt.token_hash !== hash(phoneToken)) throw new Fault(409, "connection_conflict");
        if (attempt.status === "rejected") throw this.rejection(attempt.error);
      } else {
        this.store.run("INSERT INTO connection_attempts(id,router_id,token_hash,status,expires_at) VALUES(?,?,?,'pending',?)", id, router, hash(phoneToken), this.store.now() + 300);
      }
    });
    return new Promise<Endpoint>((resolve, reject) => {
      const timer = setTimeout(() => this.fail(id, new Fault(504, "connection_timed_out")), 8000);
      this.waiting.set(id, { router, timer, resolve, reject });
      this.send(router, { type: "connect_request", requestId: id, routerId: router, phoneToken, enc, ciphertext });
    });
  }
  result(router: Endpoint, body: Record<string, unknown>) {
    if (router.role !== "router") throw new Fault(403, "router_required");
    const id = uuid(body.requestId), attempt = this.store.one<Attempt>("SELECT * FROM connection_attempts WHERE id=?", id);
    if (!attempt || attempt.router_id !== router.id || attempt.expires_at <= this.store.now()) throw new Fault(404, "connection_not_found");
    if (typeof body.ok !== "boolean") throw new Fault(400, "invalid_connection_result");
    if (!body.ok) {
      const failure = this.rejection(body.error);
      if (attempt.status === "pending") this.store.run("UPDATE connection_attempts SET status='rejected',error=? WHERE id=?", failure.code, id);
      this.fail(id, failure); return;
    }
    const phoneToken = token(body.phoneToken);
    if (hash(phoneToken) !== attempt.token_hash || attempt.status === "rejected") throw new Fault(409, "connection_conflict");
    let endpoint: Endpoint;
    try { endpoint = this.store.transaction(() => {
      const existing = this.store.one<Endpoint>("SELECT * FROM endpoints WHERE request_id=?", id);
      if (existing) {
        if (existing.revoked || existing.role !== "phone" || existing.router_id !== router.id || existing.token_hash !== attempt.token_hash) throw new Fault(409, "connection_conflict");
        return existing;
      }
      if (this.store.currentCall(router.id)) throw new Fault(409, "call_in_progress");
      const phoneID = crypto.randomUUID();
      this.store.run("INSERT INTO endpoints(id,role,router_id,token_hash,request_id) VALUES(?,'phone',?,?,?)", phoneID, router.id, attempt.token_hash, id);
      this.store.run("INSERT INTO phones(endpoint_id) VALUES(?)", phoneID);
      this.store.run("UPDATE connection_attempts SET status='approved' WHERE id=?", id);
      return this.store.endpoint(phoneID);
    }); } catch (error) {
      if (error instanceof Fault) this.fail(id, error);
      throw error;
    }
    const waiting = this.waiting.get(id);
    if (waiting) { clearTimeout(waiting.timer); this.waiting.delete(id); waiting.resolve(endpoint); }
    this.send(router.id, { type: "paired" });
  }
  offline(id: string) {
    this.keys.delete(id);
    for (const [request, waiting] of this.waiting) if (waiting.router === id) this.fail(request, new Fault(503, "router_offline"));
  }
  close() { for (const id of this.waiting.keys()) this.fail(id, new Fault(503, "service_restarting")); }
  private fail(id: string, error: Fault) {
    const waiting = this.waiting.get(id);
    if (waiting) { clearTimeout(waiting.timer); this.waiting.delete(id); waiting.reject(error); }
  }
  private rejection(code: unknown): Fault {
    if (code === "connection_rate_limited") return new Fault(429, code);
    if (code === "connection_login_expired") return new Fault(408, code);
    if (code === "connection_verification_failed") return new Fault(503, code);
    if (code === "incorrect_router_password" || code === undefined || code === null) return new Fault(401, "incorrect_router_password");
    return new Fault(400, "invalid_connection_envelope");
  }
  private bytes(value: unknown, minimum: number, maximum: number) {
    const encoded = text(value, Math.ceil(maximum / 3) * 4);
    const bytes = Buffer.from(encoded, "base64");
    if (bytes.length < minimum || bytes.length > maximum || bytes.toString("base64") !== encoded) throw new Fault(400, "invalid_connection_envelope");
    return encoded;
  }
}
