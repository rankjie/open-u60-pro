import type { Server, ServerWebSocket } from "bun";
import { createHmac } from "node:crypto";
import { Fault, object, signal, snapshot, text, uuid, type Call, type Endpoint, type Operation } from "./protocol";
import { Store } from "./store";
import type { PushProvider } from "./apns";

interface SocketData { endpoint: Endpoint; generation: string }
export interface ServiceOptions {
  hostname?: string; port?: number; store: Store; push?: PushProvider;
  turn?: { urls: string[]; secret: string };
  maintenance?: boolean;
}

export class CallingService {
  readonly server: Server<SocketData>;
  private sockets = new Map<string, ServerWebSocket<SocketData>>();
  private buckets = new Map<string, { count: number; until: number }>();
  private pushing = new Set<string>();
  private maintenance?: ReturnType<typeof setInterval>;
  constructor(readonly options: ServiceOptions) {
    const store = options.store;
    // The phone deduplicates an APNs retry by the stable CallKit call UUID.
    store.run("UPDATE push_outbox SET status='pending' WHERE status='inflight'");
    this.server = Bun.serve<SocketData>({ hostname: options.hostname ?? "127.0.0.1", port: options.port ?? 46170,
      maxRequestBodySize: 8192,
      fetch: (request, server) => this.fetch(request, server),
      websocket: {
        maxPayloadLength: 65536, idleTimeout: 30, sendPings: true, backpressureLimit: 262144,
        closeOnBackpressureLimit: true,
        open: socket => this.open(socket),
        message: (socket, message) => this.message(socket, message),
        close: socket => {
          if (this.sockets.get(socket.data.endpoint.id) === socket) {
            this.sockets.delete(socket.data.endpoint.id);
            if (socket.data.endpoint.role === "router") this.presence(socket.data.endpoint.id, false);
          }
        },
      },
    });
    if (options.maintenance !== false) this.maintenance = setInterval(() => { void this.tick(); }, 1000);
  }
  get store() { return this.options.store; }
  stop() { clearInterval(this.maintenance); this.options.push?.close(); this.server.stop(true); }
  private limit(key: string, maximum: number) {
    const now = this.store.now();
    const old = this.buckets.get(key);
    const bucket = !old || old.until <= now ? { count: 0, until: now + 60 } : old;
    if (++bucket.count > maximum) throw new Fault(429, "rate_limited");
    this.buckets.set(key, bucket);
    if (this.buckets.size > 10000) {
      for (const [id, entry] of this.buckets) if (entry.until <= now) this.buckets.delete(id);
      if (this.buckets.size > 10000) throw new Fault(503, "rate_limit_capacity");
    }
  }
  private async fetch(request: Request, server: Server<SocketData>): Promise<Response | undefined> {
    try {
      const url = new URL(request.url);
      const path = url.pathname.replace(/^\/openu60(?=\/)/, "");
      if (request.headers.has("origin")) throw new Fault(403, "browser_origin_forbidden");
      if (request.method === "GET" && path === "/health") return Response.json({ ok: true, protocol: 1, voipPushConfigured: !!this.options.push, turnConfigured: !!this.options.turn });
      const ip = server.requestIP(request)?.address ?? "unavailable";
      if (request.method === "POST" && (path === "/v1/enroll" || path === "/v1/pair")) {
        this.limit(`enroll:${ip}`, 10);
        const body = object(await this.json(request));
        const endpoint = path === "/v1/enroll" ? this.store.enroll(body) : this.store.pair(body);
        if (endpoint.role === "phone") {
          for (const socket of this.sockets.values()) if (socket.data.endpoint.role === "phone" && socket.data.endpoint.router_id === endpoint.router_id && socket.data.endpoint.id !== endpoint.id) socket.close(4001, "pairing_revoked");
          this.send(endpoint.router_id, { type: "paired" });
        }
        return Response.json({ endpointId: endpoint.id, routerId: endpoint.router_id, role: endpoint.role });
      }
      const endpoint = this.store.authenticate(request.headers.get("authorization"));
      this.limit(`api:${endpoint.id}`, 120);
      if (request.method === "GET" && path === "/v1/socket") {
        if (url.search) throw new Fault(400, "query_credentials_forbidden");
        if (server.upgrade(request, { data: { endpoint, generation: crypto.randomUUID() } })) return;
        throw new Fault(400, "websocket_upgrade_required");
      }
      if (request.method === "GET" && path === "/v1/status") {
        const call = this.store.currentCall(endpoint.router_id);
        return Response.json({ routerOnline: this.sockets.has(endpoint.router_id),
          call: call ? snapshot(call) : null, voipPushConfigured: !!this.options.push, turnConfigured: !!this.options.turn });
      }
      if (request.method === "POST" && path === "/v1/pairings") return Response.json(this.store.pairing(endpoint));
      if (request.method === "DELETE" && path === "/v1/router") {
        if (endpoint.role !== "router") throw new Fault(403, "router_required");
        if (this.store.currentCall(endpoint.id)) throw new Fault(409, "call_in_progress");
        this.store.transaction(() => {
          this.store.run("UPDATE phones SET push_token=NULL,push_disabled=1 WHERE endpoint_id IN (SELECT id FROM endpoints WHERE router_id=?)", endpoint.id);
          this.store.run("UPDATE endpoints SET revoked=1 WHERE router_id=?", endpoint.id);
          this.store.run("DELETE FROM pairings WHERE router_id=?", endpoint.id);
        });
        for (const socket of this.sockets.values()) if (socket.data.endpoint.router_id === endpoint.id) socket.close(4001, "enrollment_revoked");
        return Response.json({ ok: true });
      }
      if (request.method === "DELETE" && path === "/v1/phone") {
        if (endpoint.role !== "phone") throw new Fault(403, "phone_required");
        if (this.store.currentCall(endpoint.router_id)) throw new Fault(409, "call_in_progress");
        this.store.transaction(() => {
          this.store.run("UPDATE endpoints SET revoked=1 WHERE id=?", endpoint.id);
          this.store.run("UPDATE phones SET push_token=NULL,push_disabled=1 WHERE endpoint_id=?", endpoint.id);
        });
        this.send(endpoint.router_id, { type: "unpaired" });
        this.sockets.get(endpoint.id)?.close(4001, "pairing_revoked");
        return Response.json({ ok: true });
      }
      if (request.method === "DELETE" && path === "/v1/pairings") {
        this.store.revoke(endpoint);
        for (const socket of this.sockets.values()) {
          if (socket.data.endpoint.router_id === endpoint.id && socket.data.endpoint.role === "phone") socket.close(4001, "pairing_revoked");
        }
        return Response.json({ ok: true });
      }
      if (request.method === "DELETE" && path === "/v1/push-token") {
        if (endpoint.role !== "phone") throw new Fault(403, "phone_required");
        this.store.run("UPDATE phones SET push_token=NULL,push_disabled=1 WHERE endpoint_id=?", endpoint.id);
        return Response.json({ ok: true });
      }
      if (request.method === "PUT" && path === "/v1/push-token") {
        this.store.pushToken(endpoint, object(await this.json(request)));
        return Response.json({ ok: true });
      }
      throw new Fault(404, "not_found");
    } catch (error) {
      if (error instanceof Fault) return Response.json({ error: error.code }, { status: error.status });
      console.error("request_failed", error instanceof Error ? error.name : "unknown");
      return Response.json({ error: "internal_error" }, { status: 500 });
    }
  }
  private async json(request: Request): Promise<unknown> {
    if (!request.headers.get("content-type")?.startsWith("application/json")) throw new Fault(415, "json_required");
    try { return await request.json(); }
    catch (error) { if (error instanceof SyntaxError) throw new Fault(400, "invalid_json"); throw error; }
  }
  private send(id: string, value: unknown) {
    const socket = this.sockets.get(id);
    if (socket && socket.send(JSON.stringify(value)) === 0) socket.close(1013, "slow_consumer");
  }
  private broadcast(call: Call) {
    const event = { type: "call", ...snapshot(call) };
    this.send(call.router_id, event); this.send(call.phone_id, event);
  }
  private presence(routerId: string, online: boolean) {
    const phone = this.store.one<Endpoint>("SELECT * FROM endpoints WHERE router_id=? AND role='phone' AND revoked=0", routerId);
    if (phone) this.send(phone.id, { type: "presence", routerOnline: online });
  }
  private ice(endpoint: Endpoint) {
    if (!this.options.turn) return [];
    const username = `${this.store.now() + 3600}:${endpoint.id}`;
    const credential = createHmac("sha1", this.options.turn.secret).update(username).digest("base64");
    return [{ urls: this.options.turn.urls, username, credential }];
  }
  private refreshICE(call: Call) {
    for (const id of [call.router_id, call.phone_id]) {
      const endpoint = this.store.endpoint(id);
      this.send(id, { type: "ice_servers", iceServers: this.ice(endpoint) });
    }
  }
  private open(socket: ServerWebSocket<SocketData>) {
    const endpoint = socket.data.endpoint;
    const previous = this.sockets.get(endpoint.id);
    this.sockets.set(endpoint.id, socket);
    previous?.close(4000, "connection_replaced");
    const call = this.store.currentCall(endpoint.router_id);
    this.send(endpoint.id, { type: "hello", protocol: 1, endpointId: endpoint.id, routerId: endpoint.router_id,
      role: endpoint.role, calls: call ? [snapshot(call)] : [], iceServers: this.ice(endpoint),
      paired: !!this.store.one("SELECT 1 FROM endpoints WHERE router_id=? AND role='phone' AND revoked=0", endpoint.router_id),
      routerOnline: this.sockets.has(endpoint.router_id), voipPushConfigured: !!this.options.push });
    if (endpoint.role === "router") {
      this.presence(endpoint.id, true);
      // A delivered operation may have executed before the disconnect. The device's
      // durable journal must reconcile it instead of executing a second time.
      const operations = this.store.all<Operation>("SELECT operations.* FROM operations JOIN calls ON calls.id=operations.call_id WHERE calls.router_id=? AND status='pending' AND expires_at>?", endpoint.id, this.store.now());
      for (const operation of operations) this.send(endpoint.id, JSON.parse(operation.payload));
    }
  }
  private message(socket: ServerWebSocket<SocketData>, input: string | Buffer) {
    const endpoint = socket.data.endpoint;
    let requestId: string | undefined;
    try {
      if (this.sockets.get(endpoint.id) !== socket) throw new Fault(401, "connection_replaced");
      this.store.endpoint(endpoint.id);
      this.limit(`ws:${endpoint.id}`, 600);
      let value: unknown;
      try { value = JSON.parse(input.toString()); }
      catch (error) { if (error instanceof SyntaxError) throw new Fault(400, "invalid_json"); throw error; }
      const body = object(value);
      if (body.requestId !== undefined) requestId = uuid(body.requestId);
      switch (body.type) {
        case "ping": this.send(endpoint.id, { type: "pong" }); return;
        case "command": {
          if (!this.sockets.has(endpoint.router_id)) throw new Fault(503, "router_offline");
          const operation = this.store.command(endpoint, body);
          if (operation.action === "dial" && operation.status === "pending") this.refreshICE(this.store.call(operation.call_id));
          this.send(endpoint.id, { type: "accepted", requestId: operation.id, callId: operation.call_id });
          this.broadcast(this.store.call(operation.call_id));
          if (operation.status === "pending") this.send(endpoint.router_id, JSON.parse(operation.payload));
          else this.operationResult(operation);
          return;
        }
        case "result": {
          const { operation, call } = this.store.result(endpoint, body);
          this.operationResult(operation); this.broadcast(call); return;
        }
        case "event": {
          const call = this.store.event(endpoint, body);
          this.send(endpoint.id, { type: "event_ack", eventId: body.eventId });
          this.broadcast(call); void this.push(call.id); return;
        }
        case "signal": {
          const call = this.store.authorizeCall(endpoint, uuid(body.callId));
          if (call.state === "ended") throw new Fault(409, "call_ended");
          const message = signal(body);
          if (message.description && ((endpoint.role === "router") !== (message.description.type === "offer"))) throw new Fault(400, "invalid_sdp_direction");
          const target = endpoint.role === "router" ? call.phone_id : call.router_id;
          if (!this.sockets.has(target)) throw new Fault(503, "peer_offline");
          this.send(target, message); return;
        }
        case "media_request": {
          if (endpoint.role !== "phone") throw new Fault(403, "phone_required");
          const call = this.store.authorizeCall(endpoint, uuid(body.callId));
          if (call.state === "ended") throw new Fault(409, "call_ended");
          if (!this.sockets.has(call.router_id)) throw new Fault(503, "router_offline");
          this.refreshICE(call);
          this.send(call.router_id, { type: "media_request", callId: call.id }); return;
        }
        default: throw new Fault(400, "unknown_message");
      }
    } catch (error) {
      if (error instanceof Fault) { this.send(endpoint.id, { type: "error", requestId, error: error.code }); return; }
      console.error("message_failed", error instanceof Error ? error.name : "unknown");
      socket.close(1011, "internal_error");
    }
  }
  private operationResult(operation: Operation) {
    const call = this.store.call(operation.call_id);
    this.send(call.phone_id, { type: "result", requestId: operation.id, callId: call.id,
      ok: operation.ok === 1, error: operation.error });
  }
  private async push(callId: string) {
    if (!this.options.push || this.pushing.has(callId)) return;
    const row = this.store.one<{ phone_id: string; attempts: number }>("SELECT * FROM push_outbox WHERE call_id=? AND status='pending' AND next_attempt<=?", callId, this.store.now());
    if (!row) return;
    const call = this.store.call(callId);
    if (call.state !== "ringing" || this.store.now() - call.created_at >= 45) {
      this.store.run("UPDATE push_outbox SET status='cancelled' WHERE call_id=?", callId); return;
    }
    const phone = this.store.one<{ push_token: string | null; push_environment: "sandbox" | "production"; push_disabled: number }>("SELECT * FROM phones WHERE endpoint_id=?", row.phone_id);
    if (!phone?.push_token || phone.push_disabled) return;
    this.pushing.add(callId);
    this.store.run("UPDATE push_outbox SET status='inflight',attempts=attempts+1 WHERE call_id=?", callId);
    try {
      const outcome = await this.options.push.send(phone.push_token, phone.push_environment,
        { id: callId, routerId: call.router_id, number: call.number, expiresAt: call.created_at + 45 });
      const status = outcome.kind === "accepted" ? "accepted" : outcome.kind === "reject" ? "rejected" : "pending";
      this.store.run("UPDATE push_outbox SET status=?,last_error=?,next_attempt=? WHERE call_id=? AND status='inflight'",
        status, outcome.kind === "accepted" ? null : outcome.code, this.store.now() + Math.min(16, 2 ** row.attempts), callId);
      if (outcome.kind === "reject" && ["BadDeviceToken", "Unregistered", "DeviceTokenNotForTopic"].includes(outcome.code)) {
        this.store.run("UPDATE phones SET push_disabled=1 WHERE endpoint_id=?", row.phone_id);
      }
    } catch (error) {
      this.store.run("UPDATE push_outbox SET status='pending',last_error='provider_failure',next_attempt=? WHERE call_id=? AND status='inflight'", this.store.now() + 5, callId);
      console.error("push_provider_failed", error instanceof Error ? error.name : "unknown");
    } finally { this.pushing.delete(callId); }
  }
  async tick() {
    const expired = this.store.all<Operation>("SELECT * FROM operations WHERE status='pending' AND expires_at<=?", this.store.now());
    for (const operation of expired) {
      this.store.transaction(() => {
        this.store.run("UPDATE operations SET status='expired',ok=0,error='operation_timeout' WHERE id=? AND status='pending'", operation.id);
        if (operation.action !== "dtmf") this.store.end(operation.call_id, "operation_timeout");
      });
      this.operationResult(this.store.one<Operation>("SELECT * FROM operations WHERE id=?", operation.id)!);
      const call = this.store.call(operation.call_id);
      this.broadcast(call);
    }
    const ringing = this.store.all<Call>("SELECT * FROM calls WHERE state='ringing' AND created_at<=?", this.store.now() - 45);
    for (const call of ringing) { this.store.transaction(() => this.store.end(call.id, "no_answer")); this.broadcast(this.store.call(call.id)); }
    const pending = this.store.all<{ call_id: string }>("SELECT call_id FROM push_outbox WHERE status='pending' AND next_attempt<=?", this.store.now());
    await Promise.allSettled(pending.map(row => this.push(row.call_id))).then(results => {
      for (const result of results) if (result.status === "rejected") console.error("push_maintenance_failed");
    });
  }
}
