// GitHub webhook receiver (public via the Cloudflare tunnel). GitHub can't do
// Cloudflare Access OAuth, so the HMAC signature on the raw body is the ONLY
// inbound auth for this route — verify before trusting anything in the payload.
// Events are reduced to {repo, number} triggers and forwarded to the native
// server's /api/pr-webhook; the native side re-fetches PR state itself, so the
// payload body is never forwarded.

import { createHmac, timingSafeEqual } from "node:crypto";
import express, { type Express } from "express";
import { nativeApiBase } from "./oracle.ts";

export type SignatureCheck = "ok" | "no-secret" | "unauthorized";

/** Verify `X-Hub-Signature-256` against HMAC-SHA256(rawBody, secret). */
export function checkSignature(
  rawBody: Buffer,
  signatureHeader: string | undefined,
  secret: string | undefined,
): SignatureCheck {
  if (!secret) return "no-secret";
  if (!signatureHeader) return "unauthorized";
  const expected = Buffer.from(
    "sha256=" + createHmac("sha256", secret).update(rawBody).digest("hex"),
  );
  const got = Buffer.from(signatureHeader);
  // timingSafeEqual throws on unequal lengths, so guard first.
  if (got.length !== expected.length) return "unauthorized";
  return timingSafeEqual(got, expected) ? "ok" : "unauthorized";
}

export interface PrRef {
  repo: string;
  number: number;
}

function asRecord(v: unknown): Record<string, unknown> | undefined {
  return typeof v === "object" && v !== null ? (v as Record<string, unknown>) : undefined;
}

function prNumbersOf(container: unknown): number[] {
  const prs = asRecord(container)?.pull_requests;
  if (!Array.isArray(prs)) return [];
  return prs
    .map((pr) => asRecord(pr)?.number)
    .filter((n): n is number => typeof n === "number" && n > 0);
}

/**
 * Reduce a webhook event to the tracked-PR triggers it implies. Unknown events,
 * `ping`, and `status` (no direct commit→PR mapping; too noisy) yield nothing.
 */
export function extractPrRefs(event: string, payload: unknown): PrRef[] {
  const body = asRecord(payload);
  const repo = asRecord(body?.repository)?.full_name;
  if (typeof repo !== "string" || !repo) return [];

  const numbers: number[] = [];
  switch (event) {
    case "pull_request":
    case "pull_request_review": {
      const n = asRecord(body?.pull_request)?.number;
      if (typeof n === "number" && n > 0) numbers.push(n);
      break;
    }
    case "issue_comment": {
      const issue = asRecord(body?.issue);
      // Issue comments fire for plain issues too; only PR-backed ones matter.
      if (issue?.pull_request && typeof issue.number === "number" && issue.number > 0) {
        numbers.push(issue.number);
      }
      break;
    }
    case "check_suite":
      numbers.push(...prNumbersOf(body?.check_suite));
      break;
    case "check_run": {
      const run = asRecord(body?.check_run);
      const viaSuite = prNumbersOf(run?.check_suite);
      numbers.push(...(viaSuite.length > 0 ? viaSuite : prNumbersOf(run)));
      break;
    }
    default:
      break;
  }
  return [...new Set(numbers)].map((number) => ({ repo, number }));
}

/**
 * Fire-and-forget forward of each trigger to the native server. Failures are
 * logged, never thrown — a webhook must not crash the sidecar.
 */
export async function forwardPrRefs(refs: PrRef[], base: string = nativeApiBase()): Promise<void> {
  await Promise.all(
    refs.map(async (ref) => {
      try {
        await fetch(`${base}/api/pr-webhook`, {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify(ref),
          signal: AbortSignal.timeout(5_000),
        });
      } catch (err) {
        console.warn(
          `github-webhook: forward of ${ref.repo}#${ref.number} failed: ${err instanceof Error ? err.message : String(err)}`,
        );
      }
    }),
  );
}

/**
 * Register POST /api/github-webhook. Must be registered BEFORE the global
 * express.json() — that parser would consume the stream for application/json
 * bodies and the raw bytes needed for HMAC would be gone.
 */
export function registerGithubWebhook(app: Express): void {
  app.post("/api/github-webhook", express.raw({ type: () => true, limit: "5mb" }), (req, res) => {
    const rawBody = Buffer.isBuffer(req.body) ? req.body : Buffer.alloc(0);
    const check = checkSignature(
      rawBody,
      req.header("x-hub-signature-256"),
      process.env.JUANCODE_GH_WEBHOOK_SECRET,
    );
    if (check === "no-secret") {
      res.status(503).send("webhook secret not configured");
      return;
    }
    if (check === "unauthorized") {
      res.status(401).send("bad signature");
      return;
    }

    let payload: unknown;
    try {
      payload = JSON.parse(rawBody.toString("utf8"));
    } catch {
      res.status(400).send("invalid JSON");
      return;
    }

    // Respond fast; GitHub times webhooks out at 10s. Forwarding happens after.
    res.status(204).end();

    const event = req.header("x-github-event") ?? "";
    if (event === "ping") return;
    const refs = extractPrRefs(event, payload);
    if (refs.length > 0) void forwardPrRefs(refs);
  });
}
