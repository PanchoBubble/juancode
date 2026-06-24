import { useEffect, useRef, useState } from "react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { api } from "../lib/api.ts";

/**
 * Commit / Push / Create-PR call-to-action group for the Changes panel header,
 * in the spirit of codex and t3code. Operates on the diff panel's currently
 * targeted worktree (`cwd`, or the session's own cwd when undefined). All three
 * actions shell out to the user's real git / gh — same fidelity as everything
 * else here. `onCommitted` lets the parent refresh the diff once the working
 * tree is folded into a commit.
 */
export function GitActions({
  sessionId,
  cwd,
  onCommitted,
}: {
  sessionId: string;
  cwd?: string;
  onCommitted: () => void;
}) {
  const qc = useQueryClient();
  const [open, setOpen] = useState<"commit" | "pr" | null>(null);
  const [message, setMessage] = useState("");
  const [prTitle, setPrTitle] = useState("");
  const [prBody, setPrBody] = useState("");
  const [prDraft, setPrDraft] = useState(false);
  const [prResult, setPrResult] = useState<{ url: string; created: boolean } | null>(null);
  // A short transient status line under the buttons (push result / errors).
  const [note, setNote] = useState<{ tone: "ok" | "error"; text: string } | null>(null);
  const wrapRef = useRef<HTMLDivElement>(null);

  const git = useQuery({
    queryKey: ["git", sessionId, cwd ?? null],
    queryFn: () => api.gitState(sessionId, cwd),
    staleTime: 5_000,
  });
  const refreshGit = () => qc.invalidateQueries({ queryKey: ["git", sessionId, cwd ?? null] });

  // Prefill the PR title from the branch the first time the PR form opens.
  useEffect(() => {
    if (open === "pr" && !prTitle && git.data?.branch) setPrTitle(humanizeBranch(git.data.branch));
  }, [open, prTitle, git.data?.branch]);

  // Close any open form on outside click / Escape.
  useEffect(() => {
    if (!open) return;
    const onClick = (e: MouseEvent) => {
      if (!wrapRef.current?.contains(e.target as Node)) setOpen(null);
    };
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") setOpen(null);
    };
    window.addEventListener("click", onClick);
    window.addEventListener("keydown", onKey);
    return () => {
      window.removeEventListener("click", onClick);
      window.removeEventListener("keydown", onKey);
    };
  }, [open]);

  const genMut = useMutation({
    mutationFn: () => api.genCommitMessage(sessionId, cwd),
    onSuccess: (r) => {
      setMessage(r.message);
      setNote(null);
    },
    onError: (e) => setNote({ tone: "error", text: errText(e) }),
  });
  const commitMut = useMutation({
    mutationFn: () => api.commit(sessionId, message.trim(), cwd),
    onSuccess: (r) => {
      setMessage("");
      setOpen(null);
      setNote({ tone: "ok", text: `Committed ${r.sha} · ${r.subject}` });
      refreshGit();
      onCommitted();
    },
    onError: (e) => setNote({ tone: "error", text: errText(e) }),
  });
  const pushMut = useMutation({
    mutationFn: () => api.push(sessionId, cwd),
    onSuccess: (r) => {
      setNote({ tone: "ok", text: `Pushed ${r.branch}.` });
      refreshGit();
    },
    onError: (e) => setNote({ tone: "error", text: errText(e) }),
  });
  const prMut = useMutation({
    mutationFn: () => api.createPr(sessionId, { title: prTitle.trim(), body: prBody, draft: prDraft }, cwd),
    onSuccess: (r) => {
      setPrResult(r);
      setNote({ tone: "ok", text: r.created ? "Pull request created." : "A PR already exists for this branch." });
      refreshGit();
      qc.invalidateQueries({ queryKey: ["prs"] });
    },
    onError: (e) => setNote({ tone: "error", text: errText(e) }),
  });

  const state = git.data;
  if (state && !state.git) return null; // not a git repo — nothing to act on

  const ahead = state?.ahead ?? 0;
  const dirty = state?.dirty ?? false;
  const canPush = !!state?.remote && ahead > 0 && !state?.detached;
  const busy = commitMut.isPending || pushMut.isPending || prMut.isPending || genMut.isPending;

  const toggle = (panel: "commit" | "pr") => {
    setNote(null);
    setOpen((cur) => (cur === panel ? null : panel));
  };

  return (
    <div ref={wrapRef} className="relative flex items-center gap-2">
      <span className="h-4 w-px bg-neutral-800" />

      <button
        onClick={() => toggle("commit")}
        disabled={!dirty}
        title={dirty ? "Stage all changes and commit" : "Nothing to commit"}
        className={`rounded border px-2 py-0.5 ${
          open === "commit"
            ? "border-emerald-500 text-emerald-300"
            : "border-neutral-700 hover:border-emerald-500 hover:text-emerald-400"
        } disabled:cursor-default disabled:opacity-40`}
      >
        Commit{dirty ? " •" : ""}
      </button>

      <button
        onClick={() => pushMut.mutate()}
        disabled={!canPush || busy}
        title={
          state?.detached
            ? "Detached HEAD — checkout a branch to push"
            : !state?.remote
              ? "No git remote configured"
              : ahead > 0
                ? `Push ${ahead} commit${ahead === 1 ? "" : "s"}`
                : "Nothing to push"
        }
        className="rounded border border-neutral-700 px-2 py-0.5 hover:border-sky-500 hover:text-sky-400 disabled:cursor-default disabled:opacity-40"
      >
        {pushMut.isPending ? "Pushing…" : `Push${ahead > 0 ? ` ${ahead}` : ""}`}
      </button>

      <button
        onClick={() => toggle("pr")}
        disabled={!state?.remote || state?.detached}
        title={state?.remote ? "Open a pull request for this branch" : "No git remote configured"}
        className={`rounded border px-2 py-0.5 ${
          open === "pr"
            ? "border-violet-500 text-violet-300"
            : "border-neutral-700 hover:border-violet-500 hover:text-violet-400"
        } disabled:cursor-default disabled:opacity-40`}
      >
        PR
      </button>

      {note && (
        <span
          className={`max-w-[18rem] truncate text-[11px] ${
            note.tone === "error" ? "text-red-400" : "text-emerald-400"
          }`}
          title={note.text}
        >
          {note.text}
        </span>
      )}

      {open === "commit" && (
        <Dropdown>
          <textarea
            autoFocus
            value={message}
            onChange={(e) => setMessage(e.target.value)}
            placeholder="Commit message…"
            rows={4}
            className="w-full resize-y rounded border border-neutral-700 bg-neutral-950 px-2 py-1 text-sm text-neutral-200 placeholder:text-neutral-600 focus:border-neutral-500 focus:outline-none"
          />
          <div className="mt-2 flex items-center gap-2">
            <button
              onClick={() => genMut.mutate()}
              disabled={genMut.isPending}
              title="Draft a commit message with Claude"
              className="rounded border border-violet-700 px-2 py-0.5 text-xs text-violet-300 hover:border-violet-500 hover:text-violet-200 disabled:opacity-50"
            >
              {genMut.isPending ? "Generating…" : "✨ Generate"}
            </button>
            <button
              onClick={() => commitMut.mutate()}
              disabled={commitMut.isPending || !message.trim()}
              className="ml-auto rounded bg-emerald-700 px-3 py-0.5 text-xs font-medium text-white hover:bg-emerald-600 disabled:opacity-50"
            >
              {commitMut.isPending ? "Committing…" : "Commit all"}
            </button>
          </div>
          <p className="mt-1.5 text-[11px] text-neutral-500">Stages every change (git add -A) then commits.</p>
        </Dropdown>
      )}

      {open === "pr" && (
        <Dropdown>
          {prResult ? (
            <div className="flex flex-col gap-2 text-sm">
              <p className="text-neutral-300">
                {prResult.created ? "Pull request opened." : "A PR already exists for this branch."}
              </p>
              <a
                href={prResult.url}
                target="_blank"
                rel="noreferrer"
                className="truncate text-sky-400 hover:underline"
              >
                {prResult.url} ↗
              </a>
              <button
                onClick={() => {
                  setPrResult(null);
                  setOpen(null);
                }}
                className="self-start rounded px-2 py-0.5 text-xs text-neutral-400 hover:text-neutral-200"
              >
                Done
              </button>
            </div>
          ) : (
            <>
              <input
                autoFocus
                value={prTitle}
                onChange={(e) => setPrTitle(e.target.value)}
                placeholder="PR title"
                className="w-full rounded border border-neutral-700 bg-neutral-950 px-2 py-1 text-sm text-neutral-200 placeholder:text-neutral-600 focus:border-neutral-500 focus:outline-none"
              />
              <textarea
                value={prBody}
                onChange={(e) => setPrBody(e.target.value)}
                placeholder="Description (optional)"
                rows={4}
                className="mt-2 w-full resize-y rounded border border-neutral-700 bg-neutral-950 px-2 py-1 text-sm text-neutral-200 placeholder:text-neutral-600 focus:border-neutral-500 focus:outline-none"
              />
              <div className="mt-2 flex items-center gap-2">
                <label className="flex items-center gap-1.5 text-xs text-neutral-400">
                  <input type="checkbox" checked={prDraft} onChange={(e) => setPrDraft(e.target.checked)} />
                  Draft
                </label>
                <button
                  onClick={() => prMut.mutate()}
                  disabled={prMut.isPending || !prTitle.trim()}
                  className="ml-auto rounded bg-violet-700 px-3 py-0.5 text-xs font-medium text-white hover:bg-violet-600 disabled:opacity-50"
                >
                  {prMut.isPending ? "Creating…" : "Create PR"}
                </button>
              </div>
              <p className="mt-1.5 text-[11px] text-neutral-500">
                Pushes {state?.branch ? `“${state.branch}”` : "the branch"} first, then opens the PR.
              </p>
            </>
          )}
        </Dropdown>
      )}
    </div>
  );
}

/** A form panel anchored under the CTA group, right-aligned to its edge. */
function Dropdown({ children }: { children: React.ReactNode }) {
  return (
    <div className="absolute right-0 top-full z-30 mt-1.5 w-80 rounded-md border border-neutral-700 bg-neutral-900 p-3 shadow-xl">
      {children}
    </div>
  );
}

/** Turn a branch like "juan/add-git-ctas" into a readable default PR title. */
function humanizeBranch(branch: string): string {
  const tail = branch.split("/").pop() ?? branch;
  const words = tail.replace(/[-_]+/g, " ").trim();
  return words ? words.charAt(0).toUpperCase() + words.slice(1) : branch;
}

function errText(e: unknown): string {
  return e instanceof Error ? e.message : String(e);
}
