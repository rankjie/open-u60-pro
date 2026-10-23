import { Database, type SQLQueryBindings } from "bun:sqlite";
import { randomInt, randomUUID } from "node:crypto";
import { Fault, hash, object, phoneNumber, secret, text, token, uuid, type Call, type Endpoint, type Operation } from "./protocol";

export class Store {
  readonly db: Database;
  constructor(path: string, readonly now = () => Math.floor(Date.now() / 1000)) {
    this.db = new Database(path, { create: true, strict: true });
    this.db.exec(`PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON; PRAGMA busy_timeout=5000;
      CREATE TABLE IF NOT EXISTS endpoints(id TEXT PRIMARY KEY, role TEXT NOT NULL, router_id TEXT NOT NULL,
        token_hash TEXT UNIQUE NOT NULL, revoked INTEGER NOT NULL DEFAULT 0, request_id TEXT UNIQUE);
      CREATE TABLE IF NOT EXISTS invites(hash TEXT PRIMARY KEY, expires_at INTEGER NOT NULL,
        used_by TEXT REFERENCES endpoints(id));
      CREATE TABLE IF NOT EXISTS pairings(code_hash TEXT PRIMARY KEY, router_id TEXT NOT NULL,
        expires_at INTEGER NOT NULL, used_by TEXT REFERENCES endpoints(id));
      CREATE TABLE IF NOT EXISTS phones(endpoint_id TEXT PRIMARY KEY REFERENCES endpoints(id),
        push_token TEXT, push_environment TEXT, push_disabled INTEGER NOT NULL DEFAULT 0);
      CREATE TABLE IF NOT EXISTS calls(id TEXT PRIMARY KEY, router_id TEXT NOT NULL, phone_id TEXT NOT NULL,
        direction TEXT NOT NULL, state TEXT NOT NULL, number TEXT NOT NULL, reason TEXT,
        created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL, event_sequence INTEGER NOT NULL DEFAULT 0,
        media_ready INTEGER NOT NULL DEFAULT 0);
      CREATE UNIQUE INDEX IF NOT EXISTS one_call_per_router ON calls(router_id) WHERE state <> 'ended';
      CREATE TABLE IF NOT EXISTS operations(id TEXT PRIMARY KEY, call_id TEXT NOT NULL REFERENCES calls(id),
        action TEXT NOT NULL, fingerprint TEXT NOT NULL, payload TEXT NOT NULL, status TEXT NOT NULL,
        ok INTEGER, error TEXT, expires_at INTEGER NOT NULL);
      CREATE TABLE IF NOT EXISTS push_outbox(call_id TEXT NOT NULL REFERENCES calls(id), phone_id TEXT NOT NULL,
        status TEXT NOT NULL, attempts INTEGER NOT NULL DEFAULT 0, next_attempt INTEGER NOT NULL,
        last_error TEXT, PRIMARY KEY(call_id,phone_id));
      CREATE TABLE IF NOT EXISTS router_events(router_id TEXT NOT NULL, event_id TEXT NOT NULL,
        PRIMARY KEY(router_id,event_id));
      CREATE TABLE IF NOT EXISTS agent_operations(id TEXT NOT NULL, router_id TEXT NOT NULL,
        phone_id TEXT NOT NULL, fingerprint TEXT NOT NULL, status TEXT NOT NULL,
        expires_at INTEGER NOT NULL, PRIMARY KEY(router_id,id));
      CREATE TABLE IF NOT EXISTS notification_tokens(endpoint_id TEXT PRIMARY KEY REFERENCES endpoints(id),
        token TEXT NOT NULL, environment TEXT NOT NULL, disabled INTEGER NOT NULL DEFAULT 0);
      CREATE TABLE IF NOT EXISTS sms_events(router_id TEXT NOT NULL, event_id TEXT NOT NULL,
        phone_id TEXT NOT NULL REFERENCES endpoints(id), message_id TEXT NOT NULL, fingerprint TEXT NOT NULL, payload TEXT, received_at INTEGER NOT NULL,
        status TEXT NOT NULL, attempts INTEGER NOT NULL DEFAULT 0, next_attempt INTEGER NOT NULL,
        last_error TEXT, PRIMARY KEY(router_id,event_id,phone_id));
      CREATE TABLE IF NOT EXISTS call_participants(call_id TEXT NOT NULL REFERENCES calls(id),
        phone_id TEXT NOT NULL REFERENCES endpoints(id), dismissed INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY(call_id,phone_id));
      CREATE TABLE IF NOT EXISTS operation_phones(operation_id TEXT PRIMARY KEY REFERENCES operations(id),
        phone_id TEXT NOT NULL REFERENCES endpoints(id));
      CREATE TABLE IF NOT EXISTS missed_calls(call_id TEXT NOT NULL REFERENCES calls(id), phone_id TEXT NOT NULL REFERENCES endpoints(id),
        status TEXT NOT NULL, attempts INTEGER NOT NULL DEFAULT 0, next_attempt INTEGER NOT NULL, last_error TEXT,
        PRIMARY KEY(call_id,phone_id));`);
    this.transaction(() => {
      const callColumns = this.all<{ name: string }>("PRAGMA table_info(calls)");
      for (const [name, type] of [["phone_name", "TEXT"], ["phone_model", "TEXT"], ["answered_at", "INTEGER"], ["alerting", "INTEGER NOT NULL DEFAULT 0"]]) {
        if (!callColumns.some(column => column.name === name)) this.db.exec(`ALTER TABLE calls ADD COLUMN ${name} ${type}`);
      }
      // Older outboxes addressed one phone; preserve each existing delivery during migration.
      this.expandOutboxKey("push_outbox", ["call_id", "phone_id"]);
      this.expandOutboxKey("sms_events", ["router_id", "event_id", "phone_id"]);
      this.run("INSERT OR IGNORE INTO call_participants(call_id,phone_id) SELECT id,phone_id FROM calls WHERE phone_id<>''");
    });
  }
  private expandOutboxKey(table: "push_outbox" | "sms_events", key: string[]) {
    const columns = this.all<{ name: string; type: string; notnull: number; dflt_value: string | null; pk: number }>(`PRAGMA table_info(${table})`);
    const primary = columns.filter(column => column.pk).sort((a, b) => a.pk - b.pk).map(column => column.name);
    if (primary.join(",") === key.join(",")) return;
    const legacy = table === "push_outbox" ? "call_id" : "router_id,event_id";
    if (primary.join(",") !== legacy) throw new Error(`Unsupported ${table} primary key`);
    const definitions = columns.map(column => {
      const reference = table === "push_outbox" && column.name === "call_id" ? " REFERENCES calls(id)"
        : table === "sms_events" && column.name === "phone_id" ? " REFERENCES endpoints(id)" : "";
      return `${column.name} ${column.type}${column.notnull ? " NOT NULL" : ""}${column.dflt_value === null ? "" : ` DEFAULT ${column.dflt_value}`}${reference}`;
    });
    this.db.exec(`ALTER TABLE ${table} RENAME TO ${table}_single_phone;
      CREATE TABLE ${table}(${definitions.join(",")}, PRIMARY KEY(${key.join(",")}));
      INSERT INTO ${table} SELECT * FROM ${table}_single_phone;
      DROP TABLE ${table}_single_phone;`);
  }
  operationPhone(operation: Operation): string {
    const owner = this.one<{ phone_id: string }>("SELECT phone_id FROM operation_phones WHERE operation_id=?", operation.id)?.phone_id;
    if (owner) return owner;
    // Operations created before multi-phone support belonged to the call's single phone.
    const legacyOwner = this.call(operation.call_id).phone_id;
    if (!legacyOwner) throw new Fault(500, "operation_owner_missing");
    return legacyOwner;
  }
  phones(routerId: string): Endpoint[] {
    return this.all<Endpoint>("SELECT * FROM endpoints WHERE router_id=? AND role='phone' AND revoked=0", routerId);
  }
  phoneCall(call: Call, phone: Endpoint): Call | undefined {
    const participant = this.one<{ dismissed: number }>("SELECT dismissed FROM call_participants WHERE call_id=? AND phone_id=?", call.id, phone.id);
    if (!participant) return;
    if (participant.dismissed || (call.direction === "incoming" && call.state !== "ringing" && call.state !== "ended" && call.phone_id !== phone.id)) {
      return { ...call, state: "ended", media_ready: 0, reason: participant.dismissed ? "declined_on_device" : "answered_elsewhere" };
    }
    return call;
  }
  one<T>(sql: string, ...params: SQLQueryBindings[]): T | undefined {
    return (this.db.query(sql).get(...params) as T | null) ?? undefined;
  }
  all<T>(sql: string, ...params: SQLQueryBindings[]): T[] { return this.db.query(sql).all(...params) as T[]; }
  run(sql: string, ...params: SQLQueryBindings[]) { return this.db.query(sql).run(...params); }
  transaction<T>(body: () => T): T { return this.db.transaction(body).immediate(); }
  close() { this.db.close(); }

  invite(seconds = 600): string {
    if (seconds < 60 || seconds > 3600) throw new Fault(400, "invalid_invite_lifetime");
    const value = secret();
    this.run("INSERT INTO invites(hash,expires_at) VALUES(?,?)", hash(value), this.now() + seconds);
    return value;
  }

  enroll(body: Record<string, unknown>): Endpoint {
    const invitation = token(body.invitation), deviceToken = token(body.deviceToken), requestId = uuid(body.requestId);
    return this.transaction(() => {
      const existing = this.one<Endpoint>("SELECT * FROM endpoints WHERE request_id=?", requestId);
      if (existing) {
        if (existing.token_hash !== hash(deviceToken) || existing.role !== "router" || existing.revoked) throw new Fault(409, "enrollment_conflict");
        return existing;
      }
      const invite = this.one<{ expires_at: number; used_by: string | null }>("SELECT * FROM invites WHERE hash=?", hash(invitation));
      if (!invite || invite.used_by || invite.expires_at <= this.now()) throw new Fault(403, "invalid_invitation");
      const id = randomUUID();
      this.run("INSERT INTO endpoints(id,role,router_id,token_hash,request_id) VALUES(?,'router',?,?,?)", id, id, hash(deviceToken), requestId);
      this.run("UPDATE invites SET used_by=? WHERE hash=?", id, hash(invitation));
      return this.endpoint(id);
    });
  }

  endpoint(id: string): Endpoint {
    const endpoint = this.one<Endpoint>("SELECT * FROM endpoints WHERE id=? AND revoked=0", id);
    if (!endpoint) throw new Fault(401, "unauthorized");
    return endpoint;
  }
  authenticate(value: string | null): Endpoint {
    if (!value?.startsWith("Bearer ")) throw new Fault(401, "unauthorized");
    let credential: string;
    try { credential = token(value.slice(7)); } catch (error) { if (error instanceof Fault) throw new Fault(401, "unauthorized"); throw error; }
    const endpoint = this.one<Endpoint>("SELECT * FROM endpoints WHERE token_hash=? AND revoked=0", hash(credential));
    if (!endpoint) throw new Fault(401, "unauthorized");
    return endpoint;
  }
  pairing(endpoint: Endpoint) {
    if (endpoint.role !== "router") throw new Fault(403, "router_required");
    return this.transaction(() => {
      this.run("DELETE FROM pairings WHERE router_id=? OR expires_at<=?", endpoint.id, this.now());
      let code: string;
      do { code = String(randomInt(0, 100000000)).padStart(8, "0"); }
      while (this.one("SELECT 1 FROM pairings WHERE code_hash=?", hash(code)));
      const expiresAt = this.now() + 300;
      this.run("INSERT INTO pairings(code_hash,router_id,expires_at) VALUES(?,?,?)", hash(code), endpoint.id, expiresAt);
      return { code, expiresAt, routerId: endpoint.id };
    });
  }
  pair(body: Record<string, unknown>): Endpoint {
    const code = text(body.code, 8), phoneToken = token(body.phoneToken), requestId = uuid(body.requestId);
    if (!/^\d{8}$/.test(code)) throw new Fault(400, "invalid_pairing_code");
    return this.transaction(() => {
      const existing = this.one<Endpoint>("SELECT * FROM endpoints WHERE request_id=?", requestId);
      if (existing) {
        if (existing.token_hash !== hash(phoneToken) || existing.role !== "phone" || existing.revoked) throw new Fault(409, "pairing_conflict");
        return existing;
      }
      const pairing = this.one<{ router_id: string; expires_at: number; used_by: string | null }>("SELECT * FROM pairings WHERE code_hash=?", hash(code));
      if (!pairing || pairing.used_by || pairing.expires_at <= this.now()) throw new Fault(403, "invalid_pairing_code");
      if (this.currentCall(pairing.router_id)) throw new Fault(409, "call_in_progress");
      const id = randomUUID();
      this.run("INSERT INTO endpoints(id,role,router_id,token_hash,request_id) VALUES(?,'phone',?,?,?)", id, pairing.router_id, hash(phoneToken), requestId);
      this.run("INSERT INTO phones(endpoint_id) VALUES(?)", id);
      this.run("UPDATE pairings SET used_by=? WHERE code_hash=?", id, hash(code));
      return this.endpoint(id);
    });
  }
  call(id: string): Call {
    const call = this.one<Call>("SELECT * FROM calls WHERE id=?", id);
    if (!call) throw new Fault(404, "call_not_found");
    return call;
  }
  currentCall(routerId: string): Call | undefined { return this.one<Call>("SELECT * FROM calls WHERE router_id=? AND state<>'ended'", routerId); }
  authorizeCall(endpoint: Endpoint, id: string, allowRinging = false): Call {
    const call = this.call(id);
    if (call.router_id !== endpoint.router_id) throw new Fault(403, "call_forbidden");
    if (endpoint.role === "phone") {
      const visible = this.phoneCall(call, endpoint);
      if (!visible || (visible.state === "ended" && call.state !== "ended")) throw new Fault(409, visible?.reason ?? "call_forbidden");
      if (call.direction === "incoming" && call.state === "ringing") {
        if (!allowRinging) throw new Fault(409, "call_not_claimed");
      } else if (call.phone_id !== endpoint.id) throw new Fault(403, "call_forbidden");
    }
    return call;
  }
  pushToken(endpoint: Endpoint, body: Record<string, unknown>) {
    if (endpoint.role !== "phone") throw new Fault(403, "phone_required");
    const value = text(body.token, 512);
    if (!/^[a-f0-9]{64,512}$/i.test(value) || value.length % 2) throw new Fault(400, "invalid_push_token");
    if (body.environment !== "sandbox" && body.environment !== "production") throw new Fault(400, "invalid_push_environment");
    this.run("UPDATE phones SET push_token=?,push_environment=?,push_disabled=0 WHERE endpoint_id=?", value.toLowerCase(), body.environment, endpoint.id);
  }
  command(endpoint: Endpoint, body: Record<string, unknown>): Operation {
    if (endpoint.role !== "phone") throw new Fault(403, "phone_required");
    const id = uuid(body.requestId), callId = uuid(body.callId), action = text(body.action, 16);
    if (!["dial", "answer", "hangup", "dtmf"].includes(action)) throw new Fault(400, "invalid_action");
    const number = action === "dial" ? phoneNumber(body.number) : undefined;
    const digits = action === "dtmf" ? text(body.digits, 32) : undefined;
    if (digits && !/^[0-9*#ABCD]+$/.test(digits)) throw new Fault(400, "invalid_dtmf");
    let phone: { id: string; name: string; model: string } | undefined;
    if (body.device !== undefined) {
      if (action !== "dial" && action !== "answer") throw new Fault(400, "invalid_call_device");
      const device = object(body.device), name = text(device.name, 80).trim(), model = text(device.model, 64);
      if (!name || /[\u007f-\u009f]/.test(name) || !/^[A-Za-z0-9,._-]+$/.test(model)) throw new Fault(400, "invalid_call_device");
      phone = { id: endpoint.id, name, model };
    }
    const payload = JSON.stringify({ type: "command", requestId: id, callId, action, ...(number ? { number } : {}), ...(digits ? { digits } : {}), ...(phone ? { phone } : {}) });
    const fingerprint = hash(payload);
    const expiresAt = this.now() + 20;
    const delivery = JSON.stringify({ ...JSON.parse(payload), expiresAt });
    return this.transaction(() => {
      const previous = this.one<Operation>("SELECT * FROM operations WHERE id=?", id);
      if (previous) {
        if (this.operationPhone(previous) !== endpoint.id) throw new Fault(403, "call_forbidden");
        if (previous.fingerprint !== fingerprint) throw new Fault(409, "operation_conflict");
        return previous;
      }
      if (action === "dial") {
        if (this.currentCall(endpoint.router_id) || this.one("SELECT 1 FROM calls WHERE id=?", callId)) throw new Fault(409, "call_in_progress");
        this.run("INSERT INTO calls(id,router_id,phone_id,direction,state,number,created_at,updated_at) VALUES(?,?,?,'outgoing','dialing',?,?,?)",
          callId, endpoint.router_id, endpoint.id, number!, this.now(), this.now());
        this.run("INSERT INTO call_participants(call_id,phone_id) VALUES(?,?)", callId, endpoint.id);
        if (phone) this.run("UPDATE calls SET phone_name=?,phone_model=? WHERE id=?", phone.name, phone.model, callId);
      } else {
        const call = this.authorizeCall(endpoint, callId, true);
        if (action === "answer" && call.state !== "ringing") throw new Fault(409, "call_not_ringing");
        if (action === "dtmf" && call.state !== "active") throw new Fault(409, "call_not_active");
        if (action === "answer") {
          this.run("UPDATE calls SET state='answering',phone_id=?,updated_at=? WHERE id=?", endpoint.id, this.now(), callId);
          if (phone) this.run("UPDATE calls SET phone_name=?,phone_model=? WHERE id=?", phone.name, phone.model, callId);
          this.run("UPDATE push_outbox SET status='cancelled' WHERE call_id=? AND status='pending'", callId);
        }
        if (action === "hangup" && call.direction === "incoming" && call.state === "ringing") {
          this.run("UPDATE call_participants SET dismissed=1 WHERE call_id=? AND phone_id=?", callId, endpoint.id);
          this.run("UPDATE push_outbox SET status='cancelled' WHERE call_id=? AND phone_id=? AND status='pending'", callId, endpoint.id);
          if (this.one("SELECT 1 FROM call_participants JOIN endpoints ON endpoints.id=phone_id WHERE call_id=? AND dismissed=0 AND revoked=0", callId)) {
            this.run("INSERT INTO operations VALUES(?,?,?,?,?,'done',1,NULL,?)", id, callId, action, fingerprint, delivery, this.now());
            this.run("INSERT INTO operation_phones VALUES(?,?)", id, endpoint.id);
            return this.one<Operation>("SELECT * FROM operations WHERE id=?", id)!;
          }
        }
        if (action === "hangup" && call.state === "ended") {
          this.run("INSERT INTO operations VALUES(?,?,?,?,?,'done',1,NULL,?)", id, callId, action, fingerprint, delivery, this.now());
          this.run("INSERT INTO operation_phones VALUES(?,?)", id, endpoint.id);
          return this.one<Operation>("SELECT * FROM operations WHERE id=?", id)!;
        }
      }
      this.run("INSERT INTO operations VALUES(?,?,?,?,?,'pending',NULL,NULL,?)", id, callId, action, fingerprint, delivery, expiresAt);
      this.run("INSERT INTO operation_phones VALUES(?,?)", id, endpoint.id);
      return this.one<Operation>("SELECT * FROM operations WHERE id=?", id)!;
    });
  }
  result(endpoint: Endpoint, body: Record<string, unknown>) {
    if (endpoint.role !== "router") throw new Fault(403, "router_required");
    const id = uuid(body.requestId), callId = uuid(body.callId);
    if (typeof body.ok !== "boolean") throw new Fault(400, "invalid_result");
    const error = body.ok ? null : text(body.error, 80);
    if (error && !/^[a-z0-9_]+$/.test(error)) throw new Fault(400, "invalid_error_code");
    return this.transaction(() => {
      const operation = this.one<Operation>("SELECT * FROM operations WHERE id=? AND call_id=?", id, callId);
      if (!operation) throw new Fault(404, "operation_not_found");
      const call = this.authorizeCall(endpoint, callId);
      if (operation.status !== "pending") return { operation, call };
      this.run("UPDATE operations SET status='done',ok=?,error=? WHERE id=?", body.ok ? 1 : 0, error, id);
      if ((operation.action === "dial" || operation.action === "answer") && !body.ok) this.end(callId, error!);
      if (operation.action === "hangup" && body.ok) this.end(callId, "local_hangup");
      return { operation: this.one<Operation>("SELECT * FROM operations WHERE id=?", id)!, call: this.call(callId) };
    });
  }
  event(endpoint: Endpoint, body: Record<string, unknown>): Call {
    if (endpoint.role !== "router") throw new Fault(403, "router_required");
    const id = uuid(body.callId), eventId = uuid(body.eventId), state = text(body.state, 16);
    if (!["ringing", "dialing", "answering", "active", "ended"].includes(state)) throw new Fault(400, "invalid_call_state");
    if (!Number.isSafeInteger(body.sequence) || Number(body.sequence) < 1) throw new Fault(400, "invalid_sequence");
    if (!Number.isSafeInteger(body.observedAt) || Number(body.observedAt) < 1 || Number(body.observedAt) > this.now() + 30) throw new Fault(400, "invalid_event_time");
    if (typeof body.mediaReady !== "boolean") throw new Fault(400, "invalid_media_state");
    if (body.mediaReady && state !== "active") throw new Fault(400, "invalid_media_state");
    // The callee's phone rings: only an outgoing call that is still dialing can say so.
    if (body.alerting !== undefined && typeof body.alerting !== "boolean") throw new Fault(400, "invalid_alerting");
    if (body.alerting && state !== "dialing") throw new Fault(400, "invalid_alerting");
    const observedAt = Number(body.observedAt);
    const number = body.number === undefined ? "" : phoneNumber(body.number);
    return this.transaction(() => {
      let call = this.one<Call>("SELECT * FROM calls WHERE id=?", id);
      if (call && call.router_id !== endpoint.id) throw new Fault(403, "call_forbidden");
      if (this.one("SELECT 1 FROM router_events WHERE router_id=? AND event_id=?", endpoint.id, eventId)) {
        if (!call) throw new Fault(409, "event_conflict");
        return call;
      }
      if (!call) {
        if (state !== "ringing") throw new Fault(409, "unknown_call");
        if (this.currentCall(endpoint.id)) throw new Fault(409, "call_in_progress");
        const phones = this.phones(endpoint.id);
        if (!phones.length) throw new Fault(409, "no_paired_phone");
        // No phone owns incoming media until an answer claims the call in this transaction.
        this.run("INSERT INTO calls(id,router_id,phone_id,direction,state,number,created_at,updated_at) VALUES(?,?,?,'incoming','ringing',?,?,?)",
          id, endpoint.id, "", number, observedAt, this.now());
        for (const phone of phones) this.run("INSERT INTO call_participants(call_id,phone_id) VALUES(?,?)", id, phone.id);
        if (this.now() - observedAt >= 45) this.end(id, "stale_incoming_call");
        else for (const phone of phones) this.run("INSERT INTO push_outbox(call_id,phone_id,status,next_attempt) VALUES(?,?,'pending',?)", id, phone.id, this.now());
        call = this.call(id);
      }
      if (call.state === "ended" || Number(body.sequence) <= call.event_sequence) return call;
      if (call.direction === "incoming" && !call.phone_id && (state === "answering" || state === "active")) throw new Fault(409, "call_not_claimed");
      if ((call.state === "active" && state !== "active" && state !== "ended") || (call.direction === "outgoing" && state === "ringing") || (call.direction === "incoming" && state === "dialing") || (call.state === "answering" && state === "ringing")) {
        throw new Fault(409, "invalid_state_transition");
      }
      const reason = state === "ended" ? text(body.reason, 80) : null;
      if (reason && !/^[a-z0-9_]+$/.test(reason)) throw new Fault(400, "invalid_error_code");
      this.run("UPDATE calls SET state=?,updated_at=?,event_sequence=?,media_ready=?,reason=?,answered_at=COALESCE(answered_at,?),alerting=? WHERE id=?",
        state, this.now(), body.sequence as number, body.mediaReady === true ? 1 : 0, reason, state === "active" ? observedAt : null,
        body.alerting === true ? 1 : 0, id);
      this.run("INSERT INTO router_events VALUES(?,?)", endpoint.id, eventId);
      if (state !== "ringing") this.run("UPDATE push_outbox SET status='cancelled' WHERE call_id=? AND status='pending'", id);
      if (state === "ended") this.recordMissed(id);
      return this.call(id);
    });
  }
  end(id: string, reason: string) {
    this.run("UPDATE calls SET state='ended',reason=?,updated_at=? WHERE id=? AND state<>'ended'", reason, this.now(), id);
    this.run("UPDATE push_outbox SET status='cancelled' WHERE call_id=? AND status='pending'", id);
    this.recordMissed(id);
  }
  /** An incoming call that ended before any phone answered or declined it is missed on every phone it rang. */
  private recordMissed(id: string) {
    this.run(`INSERT OR IGNORE INTO missed_calls(call_id,phone_id,status,next_attempt)
      SELECT calls.id,call_participants.phone_id,'pending',? FROM calls JOIN call_participants ON call_participants.call_id=calls.id
      JOIN endpoints ON endpoints.id=call_participants.phone_id
      WHERE calls.id=? AND calls.state='ended' AND calls.direction='incoming' AND calls.phone_id='' AND calls.answered_at IS NULL AND endpoints.revoked=0
        AND NOT EXISTS(SELECT 1 FROM call_participants WHERE call_id=calls.id AND dismissed=1)`, this.now(), id);
  }
  revoke(router: Endpoint) {
    if (router.role !== "router") throw new Fault(403, "router_required");
    if (this.currentCall(router.id)) throw new Fault(409, "call_in_progress");
    this.transaction(() => {
      this.run("UPDATE phones SET push_token=NULL,push_disabled=1 WHERE endpoint_id IN (SELECT id FROM endpoints WHERE router_id=? AND role='phone')", router.id);
      this.run("UPDATE endpoints SET revoked=1 WHERE router_id=? AND role='phone'", router.id);
      this.run("DELETE FROM notification_tokens WHERE endpoint_id IN (SELECT id FROM endpoints WHERE router_id=?)", router.id);
      this.run("DELETE FROM pairings WHERE router_id=?", router.id);
    });
  }
}
