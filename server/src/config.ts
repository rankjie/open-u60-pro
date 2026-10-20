import { object, text } from "./protocol";
import { APNs, privateFile } from "./apns";

export function configuration(path: string) {
  const config = object(JSON.parse(privateFile(path)));
  const hostname = text(config.hostname, 255), database = text(config.database, 4096);
  if (!database.startsWith("/")) throw new Error("Database path must be absolute");
  if (typeof config.port !== "number" || !Number.isInteger(config.port) || config.port < 1024 || config.port > 65535) throw new Error("Invalid listening port");
  const publicURL = new URL(text(config.publicURL, 2048));
  if (publicURL.protocol !== "https:" || publicURL.username || publicURL.password || publicURL.search || publicURL.hash) throw new Error("Public URL must use HTTPS");
  let turn: { urls: string[]; secret: string } | undefined;
  if (config.turn !== undefined) {
    const value = object(config.turn);
    if (!Array.isArray(value.urls) || value.urls.length < 1 || value.urls.length > 4 || value.urls.some(url => typeof url !== "string" || !/^turns?:[^/?]+(:\d+)?(\?transport=(udp|tcp))?$/.test(url))) throw new Error("Invalid TURN URLs");
    const secret = privateFile(text(value.secretFile, 4096)).trim();
    if (secret.length < 32) throw new Error("TURN secret must be at least 32 characters");
    turn = { urls: value.urls as string[], secret };
  }
  let push: APNs | undefined;
  if (config.apns !== undefined) {
    const value = object(config.apns);
    push = new APNs(text(value.teamId), text(value.keyId), text(value.bundleId), privateFile(text(value.keyFile, 4096)));
  }
  return { hostname, port: config.port, database, publicURL: publicURL.toString(), turn, push };
}
