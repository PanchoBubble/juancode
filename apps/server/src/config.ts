import { existsSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

export const PORT = Number(process.env.JUANCODE_PORT ?? 4280);

/** Where the sqlite database lives. Override with JUANCODE_DATA_DIR. */
export const DATA_DIR = process.env.JUANCODE_DATA_DIR ?? join(process.cwd(), "data");

/**
 * Root the directory picker opens at (where folder search starts). Prefers an
 * explicit override, then `~/workdir` if present, else the home directory.
 */
function defaultRoot(): string {
  if (process.env.JUANCODE_DEFAULT_CWD) return process.env.JUANCODE_DEFAULT_CWD;
  const workdir = join(homedir(), "workdir");
  return existsSync(workdir) ? workdir : homedir();
}

/** Default working directory for new sessions when the client doesn't pick one. */
export const DEFAULT_CWD = defaultRoot();

/**
 * Max bytes of terminal output we keep in memory (and persist) per session for
 * replay on (re)attach. A ring buffer trims older output past this size.
 */
export const SCROLLBACK_LIMIT = Number(process.env.JUANCODE_SCROLLBACK ?? 256 * 1024);
