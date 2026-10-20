import { chmodSync, mkdirSync } from "node:fs";
import { dirname } from "node:path";
import { configuration } from "./config";
import { Store } from "./store";
import { CallingService } from "./service";

process.umask(0o077);
if (Bun.argv.length !== 3) throw new Error("Usage: bun src/main.ts /absolute/private-config.json");
const config = configuration(Bun.argv[2]);
mkdirSync(dirname(config.database), { recursive: true, mode: 0o700 });
const store = new Store(config.database);
chmodSync(config.database, 0o600);
const service = new CallingService({ ...config, store });
console.info("OpenU60 calling server listening", config.hostname, config.port,
  "VoIP push configured:", !!config.push, "TURN configured:", !!config.turn);
for (const event of ["SIGINT", "SIGTERM"] as const) {
  process.on(event, () => { service.stop(); store.close(); process.exit(0); });
}
