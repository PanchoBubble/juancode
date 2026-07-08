// node-pty ships a prebuilt `spawn-helper` binary, but pnpm drops the executable
// bit when extracting it from the tarball. Without +x, node-pty's posix_spawnp
// fails for every session. Re-apply the bit after install. Safe to run anywhere.
import { chmodSync, existsSync, readdirSync, statSync } from "node:fs";
import { join } from "node:path";

function* walk(dir, depth = 0) {
  if (depth > 8 || !existsSync(dir)) return;
  let entries;
  try {
    entries = readdirSync(dir, { withFileTypes: true });
  } catch {
    return;
  }
  for (const e of entries) {
    const full = join(dir, e.name);
    if (e.isDirectory()) {
      yield* walk(full, depth + 1);
    } else if (e.name === "spawn-helper") {
      yield full;
    }
  }
}

let fixed = 0;
for (const root of ["node_modules"]) {
  for (const helper of walk(root)) {
    try {
      const mode = statSync(helper).mode;
      if ((mode & 0o111) === 0) {
        chmodSync(helper, mode | 0o755);
        fixed++;
      }
    } catch {
      /* ignore */
    }
  }
}

if (fixed > 0) console.log(`fix-node-pty-perms: made ${fixed} spawn-helper(s) executable`);
