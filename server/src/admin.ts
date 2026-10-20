import { closeSync, mkdirSync, openSync, writeFileSync } from "node:fs";
import { dirname, isAbsolute } from "node:path";
import { Store } from "./store";
import { configuration } from "./config";

process.umask(0o077);
const [configPath, action, output] = Bun.argv.slice(2);
if (action !== "invite" || !output || !isAbsolute(output)) throw new Error("Usage: bun src/admin.ts /absolute/private-config.json invite /absolute/new-invitation-file");
const config = configuration(configPath);
mkdirSync(dirname(config.database), { recursive: true, mode: 0o700 });
const store = new Store(config.database);
const file = openSync(output, "wx", 0o600);
try { writeFileSync(file, store.invite() + "\n"); }
finally { closeSync(file); store.close(); }
console.info("Created a single-use invitation file, valid for 10 minutes.");
