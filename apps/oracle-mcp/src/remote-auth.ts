// Pairing token for remote clients (juancode-3aq8.3), the sidecar half of
// apps/native/Sources/JuancodeServer/RemoteAuth.swift. Same file, same rules: a
// request that came through a reverse proxy (`tailscale serve` forwards to
// 127.0.0.1) or from a non-loopback peer must carry the token; loopback tools don't.
import { randomBytes, timingSafeEqual } from "node:crypto";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import type { NextFunction, Request, Response } from "express";

export const tokenPath = () => join(homedir(), ".juancode", "remote-token");

/** Read the token, minting it once if missing; `wx` lets a race with the app resolve to one file. */
export function loadOrCreateToken(path = tokenPath()): string {
  try {
    const t = readFileSync(path, "utf8").trim();
    if (t) return t;
  } catch {
    // missing: mint below
  }
  mkdirSync(dirname(path), { recursive: true });
  try {
    writeFileSync(path, randomBytes(32).toString("hex"), { flag: "wx", mode: 0o600 });
  } catch {
    // lost the race to the app; read what it wrote
  }
  return readFileSync(path, "utf8").trim();
}

const LOOPBACK = new Set(["127.0.0.1", "::1", "::ffff:127.0.0.1"]);

function isRemote(req: Request): boolean {
  if (!LOOPBACK.has(req.socket.remoteAddress ?? "")) return true;
  const names = Object.keys(req.headers);
  if (names.some((n) => n.startsWith("tailscale-"))) return true;
  // shortcut: a Cloudflare Access request (the documented tunnel path) is left to Access,
  // since claude.ai's connector cannot send our token; drop this once that path is retired.
  if (req.headers["cf-access-jwt-assertion"]) return false;
  return names.includes("x-forwarded-for") || names.includes("forwarded");
}

function presented(req: Request): string | undefined {
  const auth = req.headers.authorization;
  if (auth?.startsWith("Bearer ")) return auth.slice("Bearer ".length);
  return typeof req.query.token === "string" ? req.query.token : undefined;
}

function matches(given: string | undefined, expected: string): boolean {
  if (!given) return false;
  const a = Buffer.from(given);
  const b = Buffer.from(expected);
  return a.length === b.length && timingSafeEqual(a, b);
}

export function remoteAuth(token: string) {
  return (req: Request, res: Response, next: NextFunction) => {
    if (isRemote(req) && !matches(presented(req), token)) {
      res.status(401).json({ error: "remote clients need the pairing token" });
      return;
    }
    next();
  };
}
