import { connect, type ClientHttp2Session } from "node:http2";
import { createHash, createPrivateKey, sign, type KeyObject } from "node:crypto";
import { readFileSync, lstatSync } from "node:fs";

export function privateFile(path: string): string {
  const meta = lstatSync(path, { throwIfNoEntry: true });
  if (!meta.isFile() || (meta.mode & 0o077) !== 0 || meta.size > 16384 || meta.uid !== process.getuid?.()) {
    throw new Error("Credential file must be a private, regular, process-owned file");
  }
  return readFileSync(path, "utf8");
}

export interface PushCall { id: string; routerId: string; number: string; expiresAt: number }
export interface PushSMS { id: string; routerId: string; expiresAt: number; sender: string; text: string; messageId: string }
export type PushOutcome = { kind: "accepted" | "retry" | "reject"; code: string };
export interface PushProvider {
  send(token: string, environment: "sandbox" | "production", call: PushCall): Promise<PushOutcome>;
  sendSMS(token: string, environment: "sandbox" | "production", event: PushSMS): Promise<PushOutcome>;
  close(): void;
}

export class APNs implements PushProvider {
  private readonly key: KeyObject;
  private jwt?: { value: string; issued: number };
  private sessions = new Map<string, ClientHttp2Session>();
  constructor(private readonly teamId: string, private readonly keyId: string,
    private readonly bundleId: string, keyPem: string) {
    if (!/^[A-Z0-9]{10}$/.test(teamId) || !/^[A-Z0-9]{10}$/.test(keyId)
      || !/^[A-Za-z0-9.-]+$/.test(bundleId) || !bundleId.includes(".")) throw new Error("Invalid APNs identifiers");
    this.key = createPrivateKey(keyPem);
    if (this.key.asymmetricKeyType !== "ec" || this.key.asymmetricKeyDetails?.namedCurve !== "prime256v1") {
      throw new Error("APNs requires an ES256 key");
    }
  }
  authorization(now = Math.floor(Date.now() / 1000)): string {
    if (this.jwt && now >= this.jwt.issued && now - this.jwt.issued < 2700) return this.jwt.value;
    const encode = (v: unknown) => Buffer.from(JSON.stringify(v)).toString("base64url");
    const unsigned = `${encode({ alg: "ES256", kid: this.keyId })}.${encode({ iss: this.teamId, iat: now })}`;
    const signature = sign("sha256", Buffer.from(unsigned), { key: this.key, dsaEncoding: "ieee-p1363" }).toString("base64url");
    this.jwt = { value: `${unsigned}.${signature}`, issued: now };
    return this.jwt.value;
  }
  async send(token: string, environment: "sandbox" | "production", call: PushCall): Promise<PushOutcome> {
    return this.post(token, environment, { "apns-topic": `${this.bundleId}.voip`, "apns-push-type": "voip",
      "apns-priority": "10", "apns-expiration": "0", "apns-id": call.id },
      { aps: { "content-available": 1 }, callId: call.id, routerId: call.routerId,
        handle: call.number || "Unknown", expiresAt: call.expiresAt });
  }
  async sendSMS(token: string, environment: "sandbox" | "production", event: PushSMS): Promise<PushOutcome> {
    for (const request of smsPushRequests(this.bundleId, event)) {
      const result = await this.post(token, environment, request.headers, request.payload);
      if (result.kind !== "accepted") return result;
    }
    return { kind: "accepted", code: "accepted" };
  }
  private async post(token: string, environment: "sandbox" | "production", headers: Record<string, string>, payload: unknown): Promise<PushOutcome> {
    const host = environment === "sandbox" ? "https://api.sandbox.push.apple.com" : "https://api.push.apple.com";
    let session = this.sessions.get(host);
    if (!session || session.closed || session.destroyed) {
      session = connect(host);
      session.on("error", () => { if (this.sessions.get(host) === session) this.sessions.delete(host); });
      session.setTimeout(60000, () => session?.close());
      this.sessions.set(host, session);
    }
    return new Promise(resolve => {
      let settled = false;
      let deadline: ReturnType<typeof setTimeout> | undefined;
      const finish = (outcome: PushOutcome) => { if (!settled) { settled = true; clearTimeout(deadline); resolve(outcome); } };
      const request = session!.request({ ":method": "POST", ":path": `/3/device/${token}`,
        authorization: `bearer ${this.authorization()}`, ...headers });
      deadline = setTimeout(() => { request.close(); finish({ kind: "retry", code: "apns_timeout" }); }, 8000);
      let status = 0, body = "";
      request.on("response", headers => { status = Number(headers[":status"]); });
      request.on("data", data => { if (body.length < 4096) body += data.toString(); });
      request.on("error", () => finish({ kind: "retry", code: "apns_transport" }));
      request.on("end", () => {
        if (status === 200) { finish({ kind: "accepted", code: "accepted" }); return; }
        let reason = "apns_rejected";
        try {
          const value = JSON.parse(body);
          if (typeof value.reason === "string" && /^[A-Za-z]{1,64}$/.test(value.reason)) reason = value.reason;
        } catch { /* An invalid error response is still an explicit APNs failure. */ }
        if (reason === "ExpiredProviderToken") this.jwt = undefined;
        finish({ kind: status === 429 || status >= 500 || reason === "ExpiredProviderToken" ? "retry" : "reject", code: reason });
      });
      request.end(JSON.stringify(payload));
    });
  }
  close() { for (const session of this.sessions.values()) session.destroy(); this.sessions.clear(); }
}

export function smsPushRequests(bundle: string, event: PushSMS) {
  const payload = (body: string, part: number, parts: number) => ({
    aps: { alert: { title: event.sender, subtitle: parts === 1 ? "SMS" : `SMS ${part}/${parts}`, body },
      sound: "default", "thread-id": event.routerId }, kind: "sms", eventId: event.id,
    routerId: event.routerId, messageId: event.messageId, part, parts,
  });
  const budget = 4096 - Buffer.byteLength(JSON.stringify(payload("", 9999, 9999)));
  if (budget < 100) throw new Error("SMS notification metadata exceeds the APNs limit");
  const chunks: string[] = []; let chunk = "", used = 0;
  for (const character of event.text) {
    const size = Buffer.byteLength(JSON.stringify(character)) - 2;
    if (used + size > budget) { chunks.push(chunk); chunk = ""; used = 0; }
    chunk += character; used += size;
  }
  chunks.push(chunk);
  return chunks.map((text, index) => {
    const bytes = createHash("sha256").update(`${event.id}:${index}`).digest().subarray(0, 16);
    bytes[6] = (bytes[6] & 15) | 64; bytes[8] = (bytes[8] & 63) | 128;
    const hex = bytes.toString("hex"), id = index === 0 ? event.id : `${hex.slice(0,8)}-${hex.slice(8,12)}-${hex.slice(12,16)}-${hex.slice(16,20)}-${hex.slice(20)}`;
    return { headers: { "apns-topic": bundle, "apns-push-type": "alert", "apns-priority": "10",
      "apns-expiration": String(event.expiresAt), "apns-id": id, "apns-collapse-id": `${event.id}:${index}` },
      payload: payload(text, index + 1, chunks.length) };
  });
}
