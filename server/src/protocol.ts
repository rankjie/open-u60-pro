import { createHash, randomBytes } from "node:crypto";

export class Fault extends Error {
  constructor(readonly status: number, readonly code: string) { super(code); }
}

export function object(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Fault(400, "invalid_object");
  return value as Record<string, unknown>;
}

export function text(value: unknown, max = 256): string {
  if (typeof value !== "string" || !value.length || value.length > max || /[\u0000-\u001f]/.test(value)) {
    throw new Fault(400, "invalid_text");
  }
  return value;
}

export function uuid(value: unknown): string {
  const result = text(value, 36);
  if (!/^[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$/i.test(result)) {
    throw new Fault(400, "invalid_uuid");
  }
  return result.toLowerCase();
}

export function token(value: unknown): string {
  const result = text(value, 64);
  if (!/^[A-Za-z0-9_-]{43}$/.test(result)) throw new Fault(400, "invalid_token");
  return result;
}

export function phoneNumber(value: unknown): string {
  const result = text(value, 32);
  if (!/^\+?[0-9*#]{1,30}$/.test(result)) throw new Fault(400, "invalid_number");
  return result;
}

export function hash(value: string): string { return createHash("sha256").update(value).digest("hex"); }
export function secret(): string { return randomBytes(32).toString("base64url"); }

export type Role = "router" | "phone";
export type CallState = "dialing" | "ringing" | "answering" | "active" | "ended";
export type Action = "dial" | "answer" | "hangup" | "dtmf";
export interface Endpoint { id: string; role: Role; router_id: string; token_hash: string; revoked: number }
export interface Call {
  id: string; router_id: string; phone_id: string; direction: "incoming" | "outgoing";
  state: CallState; number: string; reason: string | null; created_at: number; updated_at: number;
  event_sequence: number; media_ready: number;
  phone_name: string | null; phone_model: string | null; answered_at: number | null; alerting: number;
}
export interface Operation {
  id: string; call_id: string; action: Action; fingerprint: string; payload: string;
  status: "pending" | "done" | "expired"; ok: number | null; error: string | null; expires_at: number;
}

export function snapshot(call: Call) {
  return { callId: call.id, routerId: call.router_id, direction: call.direction, state: call.state,
    number: call.number, reason: call.reason, mediaReady: !!call.media_ready,
    updatedAt: call.updated_at, sequence: call.event_sequence, answeredAt: call.answered_at, alerting: !!call.alerting,
    phone: call.phone_id && call.phone_name && call.phone_model
      ? { id: call.phone_id, name: call.phone_name, model: call.phone_model } : null };
}

export function signal(value: Record<string, unknown>) {
  const callId = uuid(value.callId);
  if (value.description !== undefined && value.candidate === undefined) {
    const description = object(value.description);
    if (description.type !== "offer" && description.type !== "answer") throw new Fault(400, "invalid_sdp_type");
    if (typeof description.sdp !== "string" || description.sdp.length > 32768 || !description.sdp.startsWith("v=0\r\n")) {
      throw new Fault(400, "invalid_sdp");
    }
    return { type: "signal", callId, description: { type: description.type, sdp: description.sdp } };
  }
  if (value.candidate !== undefined && value.description === undefined) {
    const candidate = object(value.candidate);
    const line = text(candidate.candidate, 2048);
    if (!line.startsWith("candidate:") || !Number.isInteger(candidate.sdpMLineIndex)
      || Number(candidate.sdpMLineIndex) < 0 || Number(candidate.sdpMLineIndex) > 10) throw new Fault(400, "invalid_candidate");
    const mid = candidate.sdpMid;
    if (mid !== null && (typeof mid !== "string" || mid.length > 32 || /[\u0000-\u001f]/.test(mid))) throw new Fault(400, "invalid_candidate_mid");
    return { type: "signal", callId, candidate: { candidate: line, sdpMid: mid, sdpMLineIndex: candidate.sdpMLineIndex } };
  }
  throw new Fault(400, "invalid_signal");
}
