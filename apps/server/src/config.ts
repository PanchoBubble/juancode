import { homedir } from "node:os";
import { join } from "node:path";

export const PORT = Number(process.env.JUANCODE_PORT ?? 4280);

/** Where the sqlite database lives. Override with JUANCODE_DATA_DIR. */
export const DATA_DIR = process.env.JUANCODE_DATA_DIR ?? join(process.cwd(), "data");

/** Default working directory for new sessions when the client doesn't pick one. */
export const DEFAULT_CWD = process.env.JUANCODE_DEFAULT_CWD ?? homedir();

/**
 * Max bytes of terminal output we keep in memory (and persist) per session for
 * replay on (re)attach. A ring buffer trims older output past this size.
 */
export const SCROLLBACK_LIMIT = Number(process.env.JUANCODE_SCROLLBACK ?? 256 * 1024);
