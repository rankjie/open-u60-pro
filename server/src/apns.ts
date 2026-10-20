import { connect, type ClientHttp2Session } from "node:http2";
import { createPrivateKey, sign, type KeyObject } from "node:crypto";
import { readFileSync, lstatSync } from "node:fs";

export function privateFile(path: string): string {
  const meta = lstatSync(path, { throwIfNoEntry: true });
  if (!meta.isFile() || (meta.mode & 0o077) !== 0 || meta.size > 16384 || meta.uid !== process.getuid?.()) {
    throw new Error("Credential file must be a private, regular, process-owned file");
  }
  return readFileSync(path, "utf8");
}

export interface PushCall { id: string; routerId: string; number: string; expiresAt: number }
export type PushOutcome = { kind: "accepted" | "retry" | "reject"; code: string };
export interface PushProvider {
  send(token: string, environment: "sandbox" | "production", call: PushCall): Promise<PushOutcome>;
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
        authorization: `bearer ${this.authorization()}`, "apns-topic": `${this.bundleId}.voip`,
        "apns-push-type": "voip", "apns-priority": "10", "apns-expiration": "0", "apns-id": call.id });
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
      request.end(JSON.stringify({ aps: { "content-available": 1 }, callId: call.id,
        routerId: call.routerId, handle: call.number || "Unknown", expiresAt: call.expiresAt }));
    });
  }
  close() { for (const session of this.sessions.values()) session.destroy(); this.sessions.clear(); }
}
