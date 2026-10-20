import { Fault, hash, object, text, uuid, type Endpoint } from "./protocol";
import type { Store } from "./store";

export const AGENT_BODY_LIMIT = 65536;
export const AGENT_RESPONSE_LIMIT = 524288;
export interface AgentRequest {
  requestId: string; method: string; path: string; body: string; expiresAt: number;
}
export function agentRequest(value: unknown, now: number): AgentRequest {
  const input = object(value), requestId = uuid(input.requestId);
  const method = text(input.method, 6), path = text(input.path, 256);
  if (!["GET", "POST", "PUT", "DELETE"].includes(method)
    || !/^\/api\/[a-z0-9/-]+$/.test(path) || path.includes("//")
    || /^\/api\/(auth|remote-calling|calling|live-activity|lan|management|identity)(\/|$)/.test(path)) throw new Fault(403, "agent_path_forbidden");
  if (typeof input.body !== "string" || input.body.length > 87384
    || Buffer.from(input.body, "base64").toString("base64") !== input.body
    || Buffer.from(input.body, "base64").length > AGENT_BODY_LIMIT) throw new Fault(400, "invalid_agent_body");
  if (method === "GET" && input.body !== "") throw new Fault(400, "unexpected_agent_body");
  if (!Number.isSafeInteger(input.expiresAt) || Number(input.expiresAt) <= now
    || Number(input.expiresAt) > now + 30) throw new Fault(408, "agent_request_expired");
  return { requestId, method, path, body: input.body, expiresAt: Number(input.expiresAt) };
}
export function agentRead(request: AgentRequest): boolean {
  return request.method === "GET" || (request.method === "POST" && request.path === "/api/sms/list");
}
interface Pending {
  phone: Endpoint; request: AgentRequest; timer: ReturnType<typeof setTimeout>;
  resolve: (value: { requestId: string; status: number; body: string }) => void;
  reject: (error: Fault) => void;
}

/** Carries JSON only in memory; the durable write ledger contains fingerprints and outcomes. */
export class AgentRelay {
  private pending = new Map<string, Pending>();
  constructor(private readonly store: Store,
    private readonly online: (id: string) => boolean,
    private readonly send: (id: string, value: unknown) => boolean) {
    store.run("UPDATE agent_operations SET status='unknown' WHERE status='pending'");
  }
  private key(router: string, id: string) { return `${router}:${id}`; }
  async request(phone: Endpoint, value: unknown) {
    if (phone.role !== "phone") throw new Fault(403, "phone_required");
    const request = agentRequest(value, this.store.now()), key = this.key(phone.router_id, request.requestId);
    if (this.pending.has(key)) throw new Fault(409, "agent_request_in_progress");
    if (this.pending.size >= 256 || [...this.pending.values()].filter(p => p.phone.id === phone.id).length >= 8) throw new Fault(429, "agent_relay_busy");
    if (!this.online(phone.router_id)) throw new Fault(503, "router_offline");
    if (!agentRead(request)) {
      this.store.transaction(() => {
        const fingerprint = hash(JSON.stringify(request));
        const prior = this.store.one<{ fingerprint: string; phone_id: string; status: string }>(
          "SELECT * FROM agent_operations WHERE router_id=? AND id=?", phone.router_id, request.requestId);
        if (prior) {
          if (prior.phone_id !== phone.id || prior.fingerprint !== fingerprint) throw new Fault(409, "agent_request_conflict");
          throw new Fault(409, prior.status === "done" ? "agent_request_completed" : "agent_outcome_unknown");
        }
        this.store.run("DELETE FROM agent_operations WHERE expires_at<?", this.store.now() - 86400);
        this.store.run("INSERT INTO agent_operations(id,router_id,phone_id,fingerprint,status,expires_at) VALUES(?,?,?,?,'pending',?)",
          request.requestId, phone.router_id, phone.id, fingerprint, request.expiresAt);
      });
    }
    return new Promise<{ requestId: string; status: number; body: string }>((resolve, reject) => {
      const timeout = Math.min(20000, (request.expiresAt - this.store.now()) * 1000);
      const timer = setTimeout(() => this.fail(key, "agent_outcome_unknown"), timeout);
      this.pending.set(key, { phone, request, timer, resolve, reject });
      if (!this.send(phone.router_id, { type: "agent_request", ...request })) this.fail(key, "agent_outcome_unknown");
    });
  }
  result(router: Endpoint, input: Record<string, unknown>) {
    if (router.role !== "router") throw new Fault(403, "router_required");
    const id = uuid(input.requestId), key = this.key(router.id, id), pending = this.pending.get(key);
    if (!pending) return; // A response may arrive after its finite HTTP wait ended.
    if (!Number.isInteger(input.status) || Number(input.status) < 200 || Number(input.status) > 599
      || typeof input.body !== "string" || input.body.length > 699052
      || Buffer.from(input.body, "base64").length > AGENT_RESPONSE_LIMIT
      || Buffer.from(input.body, "base64").toString("base64") !== input.body) throw new Fault(400, "invalid_agent_result");
    try { this.store.endpoint(pending.phone.id); }
    catch (error) {
      this.fail(key, "pairing_revoked");
      if (!(error instanceof Fault)) throw error;
      return;
    }
    this.store.run("UPDATE agent_operations SET status='done' WHERE router_id=? AND id=?", router.id, id);
    clearTimeout(pending.timer); this.pending.delete(key);
    pending.resolve({ requestId: id, status: Number(input.status), body: input.body });
  }
  offline(routerId: string) {
    for (const [key, pending] of this.pending) if (pending.phone.router_id === routerId) this.fail(key, "agent_outcome_unknown");
  }
  close() { for (const key of this.pending.keys()) this.fail(key, "agent_outcome_unknown"); }
  private fail(key: string, code: string) {
    const pending = this.pending.get(key);
    if (!pending) return;
    this.store.run("UPDATE agent_operations SET status='unknown' WHERE router_id=? AND id=? AND status='pending'",
      pending.phone.router_id, pending.request.requestId);
    clearTimeout(pending.timer); this.pending.delete(key);
    pending.reject(new Fault(code === "pairing_revoked" ? 401 : 504, code));
  }
}
