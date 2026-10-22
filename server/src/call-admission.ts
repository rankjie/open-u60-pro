import { createHmac } from "node:crypto";
import { object } from "./protocol";

/** Binds direct delivery to the same phone and immutable operation admitted by the service. */
export function callAdmission(routerTokenHash: string, phoneID: string, command: Record<string, unknown>) {
  if (!/^[a-f0-9]{64}$/.test(routerTokenHash)) throw new Error("Invalid router credential verifier");
  const phone = command.phone === undefined ? undefined : object(command.phone);
  const message = ["OpenU60 call admission v1", phoneID, command.requestId, command.callId,
    command.action, String(command.expiresAt), command.number ?? "", command.digits ?? "",
    ...(phone ? [phone.id, phone.name, phone.model] : [])].join("\0");
  return { phoneId:phoneID, mac:createHmac("sha256", Buffer.from(routerTokenHash,"hex")).update(message).digest("base64url") };
}
