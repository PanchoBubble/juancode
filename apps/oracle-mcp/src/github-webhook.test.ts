import { afterEach, describe, expect, it, vi } from "vitest";
import { createHmac } from "node:crypto";
import { checkSignature, extractPrRefs, forwardPrRefs } from "./github-webhook.ts";

const SECRET = "test-secret";

function sign(body: Buffer | string, secret = SECRET): string {
  return "sha256=" + createHmac("sha256", secret).update(body).digest("hex");
}

describe("checkSignature", () => {
  const body = Buffer.from(JSON.stringify({ zen: "Keep it logically awesome." }));

  it("accepts a valid signature", () => {
    expect(checkSignature(body, sign(body), SECRET)).toBe("ok");
  });

  it("rejects a signature made with the wrong secret", () => {
    expect(checkSignature(body, sign(body, "other-secret"), SECRET)).toBe("unauthorized");
  });

  it("rejects a signature over different bytes", () => {
    expect(checkSignature(Buffer.from("tampered"), sign(body), SECRET)).toBe("unauthorized");
  });

  it("rejects a missing signature header", () => {
    expect(checkSignature(body, undefined, SECRET)).toBe("unauthorized");
  });

  it("rejects a length-mismatched header without throwing", () => {
    expect(checkSignature(body, "sha256=abc", SECRET)).toBe("unauthorized");
    expect(checkSignature(body, "", SECRET)).toBe("unauthorized");
  });

  it("reports an unset secret", () => {
    expect(checkSignature(body, sign(body), undefined)).toBe("no-secret");
    expect(checkSignature(body, sign(body), "")).toBe("no-secret");
  });
});

describe("extractPrRefs", () => {
  const repository = { full_name: "PanchoBubble/juancode" };

  it("maps pull_request to the PR number", () => {
    expect(extractPrRefs("pull_request", { repository, pull_request: { number: 12 } })).toEqual([
      { repo: "PanchoBubble/juancode", number: 12 },
    ]);
  });

  it("maps pull_request_review to the PR number", () => {
    expect(
      extractPrRefs("pull_request_review", { repository, pull_request: { number: 7 } }),
    ).toEqual([{ repo: "PanchoBubble/juancode", number: 7 }]);
  });

  it("maps issue_comment only when the issue is a PR", () => {
    const onPr = {
      repository,
      issue: { number: 3, pull_request: { url: "https://api.github.com/..." } },
    };
    expect(extractPrRefs("issue_comment", onPr)).toEqual([
      { repo: "PanchoBubble/juancode", number: 3 },
    ]);
    expect(extractPrRefs("issue_comment", { repository, issue: { number: 3 } })).toEqual([]);
  });

  it("maps check_suite to every affected PR, deduped", () => {
    const payload = {
      repository,
      check_suite: { pull_requests: [{ number: 4 }, { number: 9 }, { number: 4 }] },
    };
    expect(extractPrRefs("check_suite", payload)).toEqual([
      { repo: "PanchoBubble/juancode", number: 4 },
      { repo: "PanchoBubble/juancode", number: 9 },
    ]);
  });

  it("maps check_run via its check_suite", () => {
    const payload = {
      repository,
      check_run: { check_suite: { pull_requests: [{ number: 5 }] } },
    };
    expect(extractPrRefs("check_run", payload)).toEqual([
      { repo: "PanchoBubble/juancode", number: 5 },
    ]);
  });

  it("ignores status, ping, and unknown events", () => {
    expect(extractPrRefs("status", { repository, sha: "abc" })).toEqual([]);
    expect(extractPrRefs("ping", { repository, zen: "..." })).toEqual([]);
    expect(extractPrRefs("workflow_dispatch", { repository })).toEqual([]);
  });

  it("yields nothing without a repository full_name", () => {
    expect(extractPrRefs("pull_request", { pull_request: { number: 1 } })).toEqual([]);
    expect(extractPrRefs("pull_request", null)).toEqual([]);
  });
});

describe("forwardPrRefs", () => {
  const realFetch = globalThis.fetch;

  afterEach(() => {
    globalThis.fetch = realFetch;
    vi.restoreAllMocks();
  });

  it("POSTs each ref to the native /api/pr-webhook", async () => {
    const fetchMock = vi.fn(async () => new Response(null, { status: 200 }));
    globalThis.fetch = fetchMock as unknown as typeof fetch;

    await forwardPrRefs(
      [
        { repo: "o/r", number: 1 },
        { repo: "o/r", number: 2 },
      ],
      "http://127.0.0.1:4280",
    );

    expect(fetchMock).toHaveBeenCalledTimes(2);
    const [url, init] = fetchMock.mock.calls[0] as unknown as [string, RequestInit];
    expect(url).toBe("http://127.0.0.1:4280/api/pr-webhook");
    expect(init.method).toBe("POST");
    expect(JSON.parse(init.body as string)).toEqual({ repo: "o/r", number: 1 });
  });

  it("logs and swallows fetch failures", async () => {
    globalThis.fetch = (async () => {
      throw new Error("native app down");
    }) as unknown as typeof fetch;
    const warn = vi.spyOn(console, "warn").mockImplementation(() => {});

    await expect(forwardPrRefs([{ repo: "o/r", number: 1 }], "http://x")).resolves.toBeUndefined();
    expect(warn).toHaveBeenCalledWith(expect.stringContaining("o/r#1"));
  });
});
