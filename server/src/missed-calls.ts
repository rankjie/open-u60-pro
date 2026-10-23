import type { PushProvider } from "./apns";
import type { Store } from "./store";

interface Row { call_id: string; phone_id: string; router_id: string; number: string; ended_at: number; attempts: number; token: string; environment: "sandbox" | "production" }

/** Alerts each phone once about an incoming call nobody answered or declined; rows come from Store.recordMissed. */
export class MissedCalls {
  private pushing = new Set<string>();
  constructor(private readonly store: Store, private readonly push?: PushProvider) {
    store.run("UPDATE missed_calls SET status='pending' WHERE status='inflight'");
  }
  async tick() {
    this.store.run("UPDATE missed_calls SET status='expired' WHERE status='pending' AND (attempts>=12 OR call_id IN (SELECT id FROM calls WHERE updated_at<=?))", this.store.now() - 86400);
    const rows = this.store.all<Row>(`SELECT missed_calls.call_id,missed_calls.phone_id,missed_calls.attempts,calls.router_id,calls.number,calls.updated_at AS ended_at,
        notification_tokens.token,notification_tokens.environment FROM missed_calls JOIN calls ON calls.id=missed_calls.call_id
      JOIN notification_tokens ON notification_tokens.endpoint_id=missed_calls.phone_id JOIN endpoints ON endpoints.id=missed_calls.phone_id
      WHERE missed_calls.status='pending' AND missed_calls.next_attempt<=? AND disabled=0 AND revoked=0 LIMIT 32`, this.store.now());
    const results = await Promise.allSettled(rows.map(row => this.deliver(row)));
    for (const result of results) if (result.status === "rejected") console.error("missed_call_maintenance_failed");
  }
  private async deliver(row: Row) {
    const key = `${row.call_id}:${row.phone_id}`;
    if (!this.push?.sendMissedCall || this.pushing.has(key)) return;
    const claimed = this.store.run("UPDATE missed_calls SET status='inflight',attempts=attempts+1 WHERE call_id=? AND phone_id=? AND status='pending'", row.call_id, row.phone_id);
    if (!claimed.changes) return;
    this.pushing.add(key);
    try {
      const outcome = await this.push.sendMissedCall(row.token, row.environment,
        { id: row.call_id, routerId: row.router_id, number: row.number, expiresAt: row.ended_at + 86400 });
      this.store.run("UPDATE missed_calls SET status=?,last_error=?,next_attempt=? WHERE call_id=? AND phone_id=? AND status='inflight'",
        outcome.kind === "accepted" ? "accepted" : outcome.kind === "reject" ? "rejected" : "pending",
        outcome.kind === "accepted" ? null : outcome.code, this.store.now() + Math.min(3600, 2 ** (row.attempts + 1)), row.call_id, row.phone_id);
      if (outcome.kind === "reject" && ["BadDeviceToken", "Unregistered", "DeviceTokenNotForTopic"].includes(outcome.code)) {
        this.store.run("UPDATE notification_tokens SET disabled=1 WHERE endpoint_id=? AND token=?", row.phone_id, row.token);
      }
    } catch (error) {
      this.store.run("UPDATE missed_calls SET status='pending',last_error='provider_failure',next_attempt=? WHERE call_id=? AND phone_id=? AND status='inflight'",
        this.store.now() + 30, row.call_id, row.phone_id);
      console.error("missed_call_push_provider_failed", error instanceof Error ? error.name : "unknown");
    } finally { this.pushing.delete(key); }
  }
}
