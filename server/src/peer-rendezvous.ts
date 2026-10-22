import { Fault, signal, uuid, type Endpoint } from "./protocol";
import type { Store } from "./store";

interface Session { id: string; phone: string; router: string; expiresAt: number }

/** Authenticated introductions only; management payloads never traverse this component. */
export class PeerRendezvous {
  private sessions = new Map<string, Session>();
  constructor(private readonly store: Store,
    private readonly online: (id: string) => boolean,
    private readonly send: (id: string, value: unknown) => void,
    private readonly ice: () => unknown[]) {}

  open(phone: Endpoint, body: Record<string, unknown>) {
    if (phone.role !== "phone") throw new Fault(403, "phone_required");
    const id = uuid(body.sessionId);
    if (!this.online(phone.router_id)) throw new Fault(503, "router_offline");
    if (this.sessions.has(id)) throw new Fault(409, "peer_session_exists");
    for (const session of this.sessions.values()) if (session.phone === phone.id) this.close(session, "replaced");
    if (this.sessions.size >= 256 || [...this.sessions.values()].filter(s => s.router === phone.router_id).length >= 8) {
      throw new Fault(429, "peer_capacity");
    }
    const session = { id, phone: phone.id, router: phone.router_id, expiresAt: this.store.now() + 300 };
    this.sessions.set(id, session);
    const message = { type: "peer_session", sessionId: id, phoneId: phone.id, routerId: phone.router_id,
      expiresAt: session.expiresAt, iceServers: this.ice() };
    // The answering phone must know the session before the router emits its offer.
    this.send(phone.id, message);
    this.send(phone.router_id, message);
  }
  message(endpoint: Endpoint, body: Record<string, unknown>) {
    const session = this.sessions.get(uuid(body.sessionId));
    if (!session || (endpoint.id !== session.phone && endpoint.id !== session.router)) throw new Fault(404, "peer_session_not_found");
    if (session.expiresAt <= this.store.now()) { this.close(session, "expired"); return; }
    this.store.endpoint(session.phone); this.store.endpoint(session.router);
    if (body.type === "peer_close") { this.close(session, "closed"); return; }
    const value = signal({ ...body, callId: session.id });
    if (value.description && ((endpoint.role === "router") !== (value.description.type === "offer"))) throw new Fault(400, "invalid_sdp_direction");
    this.send(endpoint.id === session.phone ? session.router : session.phone,
      { type: "peer_signal", sessionId: session.id, ...(value.description ? { description: value.description } : { candidate: value.candidate }) });
  }
  offline(id: string) {
    for (const session of this.sessions.values()) if (session.phone === id || session.router === id) this.close(session, "peer_offline");
  }
  tick() {
    for (const session of this.sessions.values()) {
      let reason: string | undefined = session.expiresAt <= this.store.now() ? "expired" : undefined;
      try { this.store.endpoint(session.phone); this.store.endpoint(session.router); }
      catch (error) { if (!(error instanceof Fault)) throw error; reason = "pairing_revoked"; }
      if (reason) this.close(session, reason);
    }
  }
  private close(session: Session, reason: string) {
    this.sessions.delete(session.id);
    for (const id of [session.phone, session.router]) this.send(id, { type: "peer_closed", sessionId: session.id, reason });
  }
}
