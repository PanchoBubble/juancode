import {
  useEffect,
  useMemo,
  useState,
  type MouseEvent as ReactMouseEvent,
  type ReactNode,
} from "react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import {
  computeNewLineNumber,
  computeOldLineNumber,
  Diff,
  getChangeKey,
  Hunk,
  parseDiff,
  tokenize,
  type ChangeData,
  type ChangeEventArgs,
} from "react-diff-view";
import refractor from "refractor";
import { api, type NewComment } from "../lib/api.ts";
import { socket } from "../lib/socket.ts";
import { EditorModal } from "./EditorModal.tsx";
import { GitActions } from "./GitActions.tsx";
import type {
  CommentSide,
  DiffComment,
  DiffFile,
  ReviewFinding,
  ReviewResult,
  ReviewSeverity,
} from "../protocol.ts";

/** A line range being composed/extended on one side of one file's diff. */
interface Selection {
  file: string;
  side: CommentSide;
  /** Where the selection was anchored (first click). */
  line: number;
  /** Current end of the range (last/shift click). */
  endLine: number;
  /** Change key of `endLine` — where the composer widget renders. */
  changeKey: string;
}

/** Anchor a diff change to a (side, line): inserts/normals to new, deletes to old. */
function anchorOf(change: ChangeData): { side: CommentSide; line: number } {
  const n = computeNewLineNumber(change);
  if (n !== -1) return { side: "new", line: n };
  return { side: "old", line: computeOldLineNumber(change) };
}

/** Human label for a comment's anchored range, e.g. "L10" or "L10–14 (old)". */
function rangeLabel(c: { line: number; endLine: number; side: CommentSide }): string {
  const lines = c.line === c.endLine ? `L${c.line}` : `L${c.line}–${c.endLine}`;
  return c.side === "old" ? `${lines} (old)` : lines;
}

/** File extension → refractor (Prism) language id for syntax highlighting. */
const LANG_BY_EXT: Record<string, string> = {
  js: "javascript",
  mjs: "javascript",
  cjs: "javascript",
  jsx: "jsx",
  ts: "typescript",
  mts: "typescript",
  cts: "typescript",
  tsx: "tsx",
  json: "json",
  jsonc: "json",
  css: "css",
  scss: "scss",
  less: "less",
  html: "markup",
  xml: "markup",
  svg: "markup",
  vue: "markup",
  sh: "bash",
  bash: "bash",
  zsh: "bash",
  py: "python",
  rb: "ruby",
  go: "go",
  rs: "rust",
  java: "java",
  c: "c",
  h: "c",
  cpp: "cpp",
  cc: "cpp",
  hpp: "cpp",
  cs: "csharp",
  php: "php",
  sql: "sql",
  yml: "yaml",
  yaml: "yaml",
  toml: "toml",
  // NOTE: markdown is deliberately omitted. Prism's markdown grammar emits
  // multi-line tokens (code fences, tables, blockquotes, emphasis spans that
  // span newlines) which react-diff-view's per-line tokenizer can't split,
  // producing badly stretched rows. We render markdown diffs as plain text.
  swift: "swift",
  kt: "kotlin",
  lua: "lua",
};

/** Resolve a path to a language refractor actually has registered, else null. */
function langFromPath(path: string): string | null {
  const ext = path.slice(path.lastIndexOf(".") + 1).toLowerCase();
  const lang = LANG_BY_EXT[ext];
  return lang && refractor.registered(lang) ? lang : null;
}

/** DOM id for a file's diff card, so the tree can scroll it into view. */
function fileAnchorId(path: string): string {
  return `diff-file-${path.replace(/[^a-zA-Z0-9_-]/g, "_")}`;
}

const STATUS_STYLE: Record<DiffFile["status"], string> = {
  modified: "text-amber-400",
  added: "text-emerald-400",
  untracked: "text-emerald-400",
  deleted: "text-red-400",
  renamed: "text-sky-400",
};

/**
 * Compose all pending comments (+ an optional closing note) into one prompt for
 * the agent, grouped by file in diff order. Mirrors a GitHub "submit review".
 */
function composeReviewPrompt(
  files: DiffFile[],
  comments: DiffComment[],
  finalNote: string,
): string {
  const byFile = new Map<string, DiffComment[]>();
  for (const c of comments) {
    const list = byFile.get(c.file);
    if (list) list.push(c);
    else byFile.set(c.file, [c]);
  }
  const lines: string[] = ["Here are my review comments on the current working-tree changes:", ""];
  // Walk files in diff order, then any commented files not in the current diff.
  const order = [...files.map((f) => f.path), ...byFile.keys()];
  const seen = new Set<string>();
  for (const path of order) {
    if (seen.has(path)) continue;
    seen.add(path);
    const list = byFile.get(path);
    if (!list || list.length === 0) continue;
    lines.push(`### ${path}`);
    for (const c of [...list].sort((a, b) => a.line - b.line)) {
      // Indent any continuation lines so multi-line bodies stay under the bullet.
      const body = c.body.replace(/\n/g, "\n  ");
      lines.push(`- ${rangeLabel(c)}: ${body}`);
    }
    lines.push("");
  }
  const note = finalNote.trim();
  if (note) lines.push(note);
  return lines.join("\n").trimEnd();
}

export function ChangesPanel({ sessionId }: { sessionId: string }) {
  const qc = useQueryClient();
  // Selected worktree to diff (null = the session's own cwd). Reset per session.
  const [wtPath, setWtPath] = useState<string | null>(null);
  useEffect(() => setWtPath(null), [sessionId]);
  const worktrees = useQuery({
    queryKey: ["worktrees", sessionId],
    queryFn: () => api.worktrees(sessionId),
  });
  const diff = useQuery({
    queryKey: ["diff", sessionId, wtPath],
    queryFn: () => api.diff(sessionId, wtPath ?? undefined),
  });
  const comments = useQuery({
    queryKey: ["comments", sessionId],
    queryFn: () => api.comments(sessionId),
  });
  const review = useQuery({
    queryKey: ["review", sessionId],
    queryFn: () => api.review(sessionId),
  });
  const [sel, setSel] = useState<Selection | null>(null);
  const [finalNote, setFinalNote] = useState("");
  const [showSubmit, setShowSubmit] = useState(false);
  // Path (relative to the repo root) currently open in the editor overlay, if any.
  const [editing, setEditing] = useState<string | null>(null);
  // Set of file paths whose diff is collapsed (header shown, body hidden).
  const [collapsed, setCollapsed] = useState<Set<string>>(new Set());
  const toggleCollapse = (path: string) =>
    setCollapsed((prev) => {
      const next = new Set(prev);
      if (next.has(path)) next.delete(path);
      else next.add(path);
      return next;
    });
  // Free-text filter on the changed-file paths (narrows both the tree + list).
  const [query, setQuery] = useState("");
  // Worktree side panel: whether it's shown, and which folders are collapsed.
  const [showTree, setShowTree] = useState(true);
  const [collapsedDirs, setCollapsedDirs] = useState<Set<string>>(new Set());
  const toggleDir = (path: string) =>
    setCollapsedDirs((prev) => {
      const next = new Set(prev);
      if (next.has(path)) next.delete(path);
      else next.add(path);
      return next;
    });
  // Jump to a file from the tree: expand its card if collapsed, then scroll in.
  const scrollToFile = (path: string) => {
    setCollapsed((prev) => {
      if (!prev.has(path)) return prev;
      const next = new Set(prev);
      next.delete(path);
      return next;
    });
    requestAnimationFrame(() => {
      document
        .getElementById(fileAnchorId(path))
        ?.scrollIntoView({ behavior: "smooth", block: "start" });
    });
  };

  const addMut = useMutation({
    mutationFn: (c: NewComment) => api.addComment(sessionId, c),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ["comments", sessionId] });
      setSel(null);
    },
  });
  const delMut = useMutation({
    mutationFn: (commentId: string) => api.deleteComment(sessionId, commentId),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["comments", sessionId] }),
  });
  const reviewMut = useMutation({
    mutationFn: () => api.runReview(sessionId),
    onSuccess: (result) => qc.setQueryData(["review", sessionId], result),
  });
  // Submit the batched review: paste the composed prompt into the session's pty
  // (bracketed paste so newlines insert literally instead of submitting — the
  // user reviews it and presses Enter), then drop the now-delivered comments.
  const submitMut = useMutation({
    mutationFn: async () => {
      const prompt = composeReviewPrompt(diff.data?.files ?? [], comments.data ?? [], finalNote);
      socket.send({ type: "input", sessionId, data: `\x1b[200~${prompt}\x1b[201~` });
      await api.clearComments(sessionId);
    },
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ["comments", sessionId] });
      setShowSubmit(false);
      setFinalNote("");
    },
  });

  const findingsByFile = useMemo(() => {
    const map = new Map<string, ReviewFinding[]>();
    for (const f of review.data?.findings ?? []) {
      const list = map.get(f.file);
      if (list) list.push(f);
      else map.set(f.file, [f]);
    }
    return map;
  }, [review.data]);

  const commentsByFile = useMemo(() => {
    const map = new Map<string, DiffComment[]>();
    for (const c of comments.data ?? []) {
      const list = map.get(c.file);
      if (list) list.push(c);
      else map.set(c.file, [c]);
    }
    return map;
  }, [comments.data]);

  if (diff.isLoading) {
    return <Centered>Loading changes…</Centered>;
  }
  if (diff.error) {
    return <Centered tone="error">{String(diff.error)}</Centered>;
  }
  if (diff.data && !diff.data.git) {
    return <Centered>Not a git repository — nothing to diff.</Centered>;
  }
  const files = diff.data?.files ?? [];
  const root = diff.data?.root;
  // No working-tree changes, but still a git repo: keep the CTA bar so committed
  // work can be pushed / turned into a PR (a commit clears the diff but not the
  // need to ship it).
  if (files.length === 0) {
    return (
      <div className="flex h-full flex-col bg-neutral-950">
        <div className="flex items-center justify-end gap-2 border-b border-neutral-800 px-4 py-2 text-xs text-neutral-400">
          <button
            onClick={() => diff.refetch()}
            className="rounded border border-neutral-700 px-2 py-0.5 hover:border-neutral-500 hover:text-neutral-200"
          >
            Refresh
          </button>
          <GitActions sessionId={sessionId} cwd={wtPath ?? undefined} onCommitted={() => diff.refetch()} />
        </div>
        <Centered>No changes in the working tree.</Centered>
      </div>
    );
  }

  const totals = files.reduce(
    (acc, f) => ({ add: acc.add + f.additions, del: acc.del + f.deletions }),
    { add: 0, del: 0 },
  );
  const q = query.trim().toLowerCase();
  const visibleFiles = q ? files.filter((f) => f.path.toLowerCase().includes(q)) : files;
  const pendingCount = comments.data?.length ?? 0;
  const allCollapsed = files.every((f) => collapsed.has(f.path));

  return (
    <div className="flex h-full flex-col bg-neutral-950">
      <div className="sticky top-0 z-10 flex flex-wrap items-center gap-3 border-b border-neutral-800 bg-neutral-950 px-4 py-2 text-xs text-neutral-400">
        <span>
          {q ? `${visibleFiles.length}/${files.length}` : files.length} file
          {files.length === 1 ? "" : "s"}
        </span>
        <span className="text-emerald-400">+{totals.add}</span>
        <span className="text-red-400">−{totals.del}</span>
        {diff.data?.truncatedFiles && <span className="text-amber-500">(list capped)</span>}
        {worktrees.data && worktrees.data.length > 1 && (
          <select
            value={wtPath ?? diff.data?.root ?? ""}
            onChange={(e) => setWtPath(e.target.value)}
            title="Show the working-tree status of this worktree"
            className="max-w-[16rem] rounded border border-neutral-700 bg-neutral-950 px-1.5 py-0.5 text-neutral-200 focus:border-neutral-500 focus:outline-none"
          >
            {worktrees.data.map((w) => (
              <option key={w.path} value={w.path}>
                {(w.branch ?? w.path.split("/").filter(Boolean).pop() ?? w.path) + (w.main ? " (main)" : "")}
              </option>
            ))}
          </select>
        )}
        <div className="ml-auto flex items-center gap-2">
          <input
            value={query}
            onChange={(e) => setQuery(e.target.value)}
            placeholder="Filter files…"
            className="w-40 rounded border border-neutral-700 bg-neutral-950 px-2 py-0.5 text-neutral-200 placeholder:text-neutral-600 focus:border-neutral-500 focus:outline-none"
          />
          <button
            onClick={() => setShowTree((v) => !v)}
            title={showTree ? "Hide the file tree" : "Show the file tree"}
            className={`rounded border px-2 py-0.5 ${
              showTree
                ? "border-neutral-600 text-neutral-200"
                : "border-neutral-700 hover:border-neutral-500 hover:text-neutral-200"
            }`}
          >
            Files
          </button>
          <button
            onClick={() =>
              setCollapsed(allCollapsed ? new Set() : new Set(files.map((f) => f.path)))
            }
            title={allCollapsed ? "Expand every file" : "Collapse every file"}
            className="rounded border border-neutral-700 px-2 py-0.5 hover:border-neutral-500 hover:text-neutral-200"
          >
            {allCollapsed ? "Expand all" : "Collapse all"}
          </button>
          <button
            onClick={() => reviewMut.mutate()}
            disabled={reviewMut.isPending}
            title="Run Claude over this diff and overlay its findings"
            className="rounded border border-violet-700 px-2 py-0.5 text-violet-300 hover:border-violet-500 hover:text-violet-200 disabled:opacity-50"
          >
            {reviewMut.isPending ? "Reviewing…" : "Review with Claude"}
          </button>
          <button
            onClick={() => {
              diff.refetch();
              comments.refetch();
            }}
            className="rounded border border-neutral-700 px-2 py-0.5 hover:border-neutral-500 hover:text-neutral-200"
          >
            Refresh
          </button>
          <GitActions
            sessionId={sessionId}
            cwd={wtPath ?? undefined}
            onCommitted={() => {
              diff.refetch();
              comments.refetch();
            }}
          />
        </div>
      </div>
      <ReviewSummary
        pending={reviewMut.isPending}
        error={reviewMut.error ? String(reviewMut.error) : null}
        result={review.data ?? null}
      />
      <div className="flex min-h-0 flex-1">
        {showTree && (
          <div className="w-56 shrink-0 overflow-auto border-r border-neutral-800 p-2 font-mono text-xs text-neutral-400">
            <FileTree
              files={visibleFiles}
              collapsedDirs={collapsedDirs}
              onToggleDir={toggleDir}
              onPick={scrollToFile}
            />
          </div>
        )}
        <div className="min-h-0 flex-1 overflow-y-auto">
          <div className="flex flex-col gap-4 p-4">
            {visibleFiles.length === 0 ? (
              <p className="px-1 py-2 text-xs text-neutral-500">No files match “{query}”.</p>
            ) : null}
            {visibleFiles.map((file) => (
              <FileCard
                key={file.path}
                file={file}
                comments={commentsByFile.get(file.path) ?? []}
                findings={findingsByFile.get(file.path) ?? []}
                selection={sel?.file === file.path ? sel : null}
                onGutterClick={setSel}
                onCancel={() => setSel(null)}
                onSubmit={(c) => addMut.mutate(c)}
                onDelete={(id) => delMut.mutate(id)}
                onEdit={
                  root && file.status !== "deleted" && !file.binary
                    ? () => setEditing(file.path)
                    : undefined
                }
                collapsed={collapsed.has(file.path)}
                onToggleCollapse={() => toggleCollapse(file.path)}
                submitting={addMut.isPending}
              />
            ))}
          </div>
        </div>
      </div>
      {pendingCount > 0 && (
        <div className="border-t border-neutral-800 bg-neutral-900">
          {showSubmit && (
            <div className="border-b border-neutral-800 px-4 py-2">
              <textarea
                autoFocus
                value={finalNote}
                onChange={(e) => setFinalNote(e.target.value)}
                placeholder="Optional closing note for the agent…"
                rows={2}
                className="w-full resize-y rounded border border-neutral-700 bg-neutral-950 px-2 py-1 text-sm text-neutral-200 placeholder:text-neutral-600 focus:border-neutral-500 focus:outline-none"
              />
              <p className="mt-1 text-[11px] text-neutral-500">
                Comments are pasted into the terminal prompt — press Enter there to send.
              </p>
            </div>
          )}
          <div className="flex items-center gap-3 px-4 py-2 text-xs">
            <span className="text-neutral-400">
              {pendingCount} comment{pendingCount === 1 ? "" : "s"} pending
            </span>
            <div className="ml-auto flex items-center gap-2">
              {showSubmit && (
                <button
                  onClick={() => setShowSubmit(false)}
                  className="rounded px-2 py-0.5 text-neutral-400 hover:text-neutral-200"
                >
                  Cancel
                </button>
              )}
              <button
                onClick={() => (showSubmit ? submitMut.mutate() : setShowSubmit(true))}
                disabled={submitMut.isPending}
                className="rounded bg-emerald-700 px-3 py-0.5 font-medium text-white hover:bg-emerald-600 disabled:opacity-50"
              >
                {submitMut.isPending
                  ? "Sending…"
                  : showSubmit
                    ? "Send to agent"
                    : "Submit review →"}
              </button>
            </div>
          </div>
        </div>
      )}
      {editing && root && (
        <EditorModal
          cwd={root}
          file={editing}
          onClose={() => {
            setEditing(null);
            // The file may have changed on disk — refresh the diff + comments.
            diff.refetch();
            comments.refetch();
          }}
        />
      )}
    </div>
  );
}

const SEVERITY_STYLE: Record<ReviewSeverity, string> = {
  critical: "bg-red-900/60 text-red-300 border-red-700",
  high: "bg-orange-900/50 text-orange-300 border-orange-700",
  medium: "bg-amber-900/40 text-amber-300 border-amber-700",
  low: "bg-sky-900/40 text-sky-300 border-sky-700",
  info: "bg-neutral-800 text-neutral-300 border-neutral-600",
};

function SeverityBadge({ severity }: { severity: ReviewSeverity }) {
  return (
    <span
      className={`shrink-0 rounded border px-1.5 py-0.5 text-[10px] font-medium uppercase ${SEVERITY_STYLE[severity]}`}
    >
      {severity}
    </span>
  );
}

/** A single AI finding card, used both inline (anchored) and in a file's strip. */
function FindingItem({ finding }: { finding: ReviewFinding }) {
  return (
    <div className="mb-1.5 rounded border border-violet-900/60 bg-violet-950/30 px-2 py-1.5">
      <div className="flex items-start gap-2">
        <SeverityBadge severity={finding.severity} />
        <div className="min-w-0 flex-1">
          {finding.title && <p className="font-medium text-neutral-100">{finding.title}</p>}
          <p className="whitespace-pre-wrap break-words text-neutral-300">{finding.note}</p>
        </div>
        <span className="shrink-0 text-[10px] text-violet-400">✨ Claude</span>
      </div>
    </div>
  );
}

/** Header banner: spinner while running, error, or the model's summary + counts. */
function ReviewSummary({
  pending,
  error,
  result,
}: {
  pending: boolean;
  error: string | null;
  result: ReviewResult | null;
}) {
  if (pending) {
    return (
      <div className="border-b border-violet-900/60 bg-violet-950/30 px-4 py-2 text-xs text-violet-300">
        Claude is reviewing the diff…
      </div>
    );
  }
  if (error) {
    return (
      <div className="border-b border-red-900/60 bg-red-950/30 px-4 py-2 text-xs text-red-300">
        {error}
      </div>
    );
  }
  if (!result) return null;
  if (result.status === "error") {
    return (
      <div className="border-b border-red-900/60 bg-red-950/30 px-4 py-2 text-xs text-red-300">
        Review failed: {result.error ?? "unknown error"}
      </div>
    );
  }
  const count = result.findings.length;
  return (
    <div className="border-b border-violet-900/60 bg-violet-950/20 px-4 py-2 text-xs text-neutral-300">
      <div className="flex items-center gap-2">
        <span className="font-medium text-violet-300">✨ Claude review</span>
        <span className="text-neutral-500">
          {count} finding{count === 1 ? "" : "s"} · {new Date(result.createdAt).toLocaleString()}
        </span>
      </div>
      {result.summary && (
        <p className="mt-1 whitespace-pre-wrap break-words text-neutral-400">{result.summary}</p>
      )}
    </div>
  );
}

interface FileCardProps {
  file: DiffFile;
  comments: DiffComment[];
  findings: ReviewFinding[];
  selection: Selection | null;
  onGutterClick: (s: Selection) => void;
  onCancel: () => void;
  onSubmit: (c: NewComment) => void;
  onDelete: (id: string) => void;
  /** Open this file in the editor overlay; omitted when not editable. */
  onEdit?: () => void;
  collapsed: boolean;
  onToggleCollapse: () => void;
  submitting: boolean;
}

function FileCard({
  file,
  comments,
  findings,
  selection,
  onGutterClick,
  onCancel,
  onSubmit,
  onDelete,
  onEdit,
  collapsed,
  onToggleCollapse,
  submitting,
}: FileCardProps) {
  const parsed = useMemo(() => (file.diff ? parseDiff(file.diff)[0] : undefined), [file.diff]);

  // Syntax-highlight the diff with refractor (Prism). Falls back to plain text
  // for languages refractor doesn't have, or if tokenizing throws.
  const tokens = useMemo(() => {
    if (!parsed) return undefined;
    const language = langFromPath(file.path);
    if (!language) return undefined;
    try {
      return tokenize(parsed.hunks, { highlight: true, refractor, language });
    } catch {
      return undefined;
    }
  }, [parsed, file.path]);

  // Build the inline widgets (comments + anchored AI findings) and, alongside,
  // the findings we can't anchor onto the current diff (file-level, or a line no
  // longer present) — those render in a strip under the header instead. Comments
  // anchor on their range's end line (falling back to the start line).
  const { widgets, orphanFindings, selectedChanges } = useMemo(() => {
    const orphans: ReviewFinding[] = [];
    if (!parsed) {
      return {
        widgets: {} as Record<string, ReactNode>,
        orphanFindings: findings,
        selectedChanges: [] as string[],
      };
    }
    // Map every (side:line) in this file's diff to its react-diff-view change key.
    const keyByAnchor = new Map<string, string>();
    for (const hunk of parsed.hunks) {
      for (const change of hunk.changes) {
        const a = anchorOf(change);
        keyByAnchor.set(`${a.side}:${a.line}`, getChangeKey(change));
      }
    }
    const keyFor = (c: DiffComment) =>
      keyByAnchor.get(`${c.side}:${c.endLine}`) ?? keyByAnchor.get(`${c.side}:${c.line}`);

    // Group existing comments by the change key their (end) line resolves to.
    const groupedComments = new Map<string, DiffComment[]>();
    for (const c of comments) {
      const key = keyFor(c);
      if (!key) continue; // line no longer present in the current diff
      const list = groupedComments.get(key);
      if (list) list.push(c);
      else groupedComments.set(key, [c]);
    }
    // Group AI findings the same way; unanchorable ones fall to the strip.
    const groupedFindings = new Map<string, ReviewFinding[]>();
    for (const f of findings) {
      const key = f.line === null ? undefined : keyByAnchor.get(`${f.side}:${f.line}`);
      if (!key) {
        orphans.push(f);
        continue;
      }
      const list = groupedFindings.get(key);
      if (list) list.push(f);
      else groupedFindings.set(key, [f]);
    }

    const keys = new Set([...groupedComments.keys(), ...groupedFindings.keys()]);
    if (selection) keys.add(selection.changeKey);

    const result: Record<string, ReactNode> = {};
    for (const key of keys) {
      const list = groupedComments.get(key) ?? [];
      const fList = groupedFindings.get(key) ?? [];
      const isActive = selection?.changeKey === key;
      const lo = selection ? Math.min(selection.line, selection.endLine) : 0;
      const hi = selection ? Math.max(selection.line, selection.endLine) : 0;
      result[key] = (
        <div className="border-y border-neutral-800 bg-neutral-900/60 px-4 py-2 text-sm">
          {fList.map((f, i) => (
            <FindingItem key={`f${i}`} finding={f} />
          ))}
          {list.map((c) => (
            <CommentItem key={c.id} comment={c} onDelete={() => onDelete(c.id)} />
          ))}
          {isActive ? (
            <Composer
              label={lo === hi ? `Line ${lo}` : `Lines ${lo}–${hi}`}
              submitting={submitting}
              onCancel={onCancel}
              onSubmit={(body) =>
                onSubmit({ file: file.path, side: selection!.side, line: lo, endLine: hi, body })
              }
            />
          ) : (
            list.length > 0 && (
              <button
                onClick={() =>
                  onGutterClick({
                    file: file.path,
                    side: list[0]!.side,
                    line: list[0]!.line,
                    endLine: list[0]!.endLine,
                    changeKey: key,
                  })
                }
                className="text-xs text-neutral-500 hover:text-neutral-300"
              >
                Reply
              </button>
            )
          )}
        </div>
      );
    }

    // Highlight every change in the active range (shift-click selection).
    const selected: string[] = [];
    if (selection) {
      const lo = Math.min(selection.line, selection.endLine);
      const hi = Math.max(selection.line, selection.endLine);
      for (const [anchor, key] of keyByAnchor) {
        const [sideStr, lineStr] = anchor.split(":");
        const ln = Number(lineStr);
        if (sideStr === selection.side && ln >= lo && ln <= hi) selected.push(key);
      }
    }
    return { widgets: result, orphanFindings: orphans, selectedChanges: selected };
  }, [
    parsed,
    comments,
    findings,
    selection,
    file.path,
    submitting,
    onGutterClick,
    onCancel,
    onSubmit,
    onDelete,
  ]);

  // Click a gutter to start a selection; shift-click to extend the range on the
  // same side. Clicking elsewhere starts a fresh single-line selection.
  const onGutter = (args: ChangeEventArgs, event: ReactMouseEvent) => {
    const change = args.change;
    if (!change) return;
    const a = anchorOf(change);
    const key = getChangeKey(change);
    if (event.shiftKey && selection && selection.side === a.side) {
      onGutterClick({ ...selection, endLine: a.line, changeKey: key });
    } else {
      onGutterClick({
        file: file.path,
        side: a.side,
        line: a.line,
        endLine: a.line,
        changeKey: key,
      });
    }
  };

  return (
    <div
      id={fileAnchorId(file.path)}
      className="scroll-mt-2 overflow-hidden rounded-md border border-neutral-800"
    >
      <div className="flex items-center gap-2 border-b border-neutral-800 bg-neutral-900 px-3 py-1.5 font-mono text-xs">
        <button
          onClick={onToggleCollapse}
          title={collapsed ? "Expand diff" : "Collapse diff"}
          className="flex min-w-0 flex-1 items-center gap-2 text-left hover:text-neutral-100"
        >
          <span className="shrink-0 text-neutral-500">{collapsed ? "▸" : "▾"}</span>
          <span className={STATUS_STYLE[file.status]}>{file.status}</span>
          <span className="truncate text-neutral-300">
            {file.oldPath ? `${file.oldPath} → ${file.path}` : file.path}
          </span>
        </button>
        <span className="shrink-0 text-neutral-500">
          <span className="text-emerald-400">+{file.additions}</span>{" "}
          <span className="text-red-400">−{file.deletions}</span>
        </span>
        {onEdit && (
          <button
            onClick={onEdit}
            title="Open this file in your editor (nvim)"
            className="shrink-0 rounded border border-neutral-700 px-1.5 py-0.5 text-[11px] text-neutral-300 hover:border-emerald-500 hover:text-emerald-400"
          >
            Edit
          </button>
        )}
      </div>
      {!collapsed && (
        <>
          {orphanFindings.length > 0 && (
            <div className="border-b border-neutral-800 bg-neutral-900/40 px-3 py-2 text-sm">
              {orphanFindings.map((f, i) => (
                <FindingItem key={`o${i}`} finding={f} />
              ))}
            </div>
          )}
          {file.binary ? (
            <p className="px-3 py-2 text-xs text-neutral-500">Binary file — diff not shown.</p>
          ) : file.truncated ? (
            <p className="px-3 py-2 text-xs text-neutral-500">Diff too large to display.</p>
          ) : parsed ? (
            <div className="diff-dark overflow-x-auto text-[12px]">
              <Diff
                viewType="unified"
                diffType={parsed.type}
                hunks={parsed.hunks}
                tokens={tokens}
                widgets={widgets}
                selectedChanges={selectedChanges}
                gutterEvents={{ onClick: onGutter }}
              >
                {(hunks) => hunks.map((hunk) => <Hunk key={hunk.content} hunk={hunk} />)}
              </Diff>
            </div>
          ) : (
            <p className="px-3 py-2 text-xs text-neutral-500">No textual changes.</p>
          )}
        </>
      )}
    </div>
  );
}

function CommentItem({ comment, onDelete }: { comment: DiffComment; onDelete: () => void }) {
  return (
    <div className="group mb-1.5 rounded bg-neutral-800/60 px-2 py-1.5">
      <div className="flex items-start gap-2">
        <div className="min-w-0 flex-1">
          <span className="mr-1.5 font-mono text-[10px] text-neutral-500">
            {rangeLabel(comment)}
          </span>
          <span className="whitespace-pre-wrap break-words text-neutral-200">{comment.body}</span>
        </div>
        <button
          onClick={onDelete}
          title="Delete comment"
          className="shrink-0 text-neutral-600 opacity-0 transition group-hover:opacity-100 hover:text-red-400"
        >
          ✕
        </button>
      </div>
      <time className="text-[10px] text-neutral-500">
        {new Date(comment.createdAt).toLocaleString()}
      </time>
    </div>
  );
}

function Composer({
  label,
  onSubmit,
  onCancel,
  submitting,
}: {
  label: string;
  onSubmit: (body: string) => void;
  onCancel: () => void;
  submitting: boolean;
}) {
  const [body, setBody] = useState("");
  const submit = () => {
    if (body.trim()) onSubmit(body.trim());
  };
  return (
    <div className="mt-1">
      <div className="mb-1 text-[11px] text-neutral-500">
        {label} · shift-click another line to extend the range
      </div>
      <textarea
        autoFocus
        value={body}
        onChange={(e) => setBody(e.target.value)}
        onKeyDown={(e) => {
          if ((e.metaKey || e.ctrlKey) && e.key === "Enter") submit();
          if (e.key === "Escape") onCancel();
        }}
        placeholder="Leave a comment… (⌘/Ctrl+Enter to save)"
        rows={2}
        className="w-full resize-y rounded border border-neutral-700 bg-neutral-950 px-2 py-1 text-sm text-neutral-200 placeholder:text-neutral-600 focus:border-neutral-500 focus:outline-none"
      />
      <div className="mt-1 flex gap-2">
        <button
          onClick={submit}
          disabled={submitting || !body.trim()}
          className="rounded bg-emerald-700 px-2 py-0.5 text-xs text-white hover:bg-emerald-600 disabled:opacity-50"
        >
          Comment
        </button>
        <button
          onClick={onCancel}
          className="rounded px-2 py-0.5 text-xs text-neutral-400 hover:text-neutral-200"
        >
          Cancel
        </button>
      </div>
    </div>
  );
}

// ── Worktree file tree (collapsible side panel listing the changed files) ────

interface TreeNode {
  /** Display name; for collapsed dir chains this is "a/b/c". */
  name: string;
  /** Full path: the file path for files, the directory path for folders. */
  path: string;
  /** Present for directories; absent for leaf files. */
  children?: TreeNode[];
  file?: DiffFile;
}

/** Build a nested tree from the flat changed-file list, sorting dirs before files. */
function buildFileTree(files: DiffFile[]): TreeNode[] {
  const root = new Map<string, TreeNode>();
  for (const f of files) {
    const parts = f.path.split("/");
    let level = root;
    for (let i = 0; i < parts.length; i++) {
      const part = parts[i]!;
      const isFile = i === parts.length - 1;
      if (isFile) {
        level.set(part, { name: part, path: f.path, file: f });
      } else {
        let dir = level.get(part);
        if (!dir || !dir.children) {
          dir = { name: part, path: parts.slice(0, i + 1).join("/"), children: [] };
          level.set(part, dir);
        }
        // Reuse the dir's child map via a side table keyed on the node object.
        level = childMap(dir);
      }
    }
  }
  return materialize(root);
}

// Each directory node carries a live Map of its children during construction;
// `materialize` flattens those maps into sorted arrays and collapses single-
// child directory chains (a → a/b → a/b/c) into one row, VS Code style.
const childMaps = new WeakMap<TreeNode, Map<string, TreeNode>>();
function childMap(node: TreeNode): Map<string, TreeNode> {
  let m = childMaps.get(node);
  if (!m) {
    m = new Map();
    childMaps.set(node, m);
  }
  return m;
}
function materialize(level: Map<string, TreeNode>): TreeNode[] {
  const nodes = [...level.values()].map((node) => {
    if (!node.children) return node;
    let collapsed = node;
    let kids = materialize(childMap(collapsed));
    // Collapse a lone sub-directory into the parent's name.
    while (kids.length === 1 && kids[0]!.children) {
      const only = kids[0]!;
      collapsed = { name: `${collapsed.name}/${only.name}`, path: only.path, children: [] };
      kids = materialize(childMap(only));
    }
    return { ...collapsed, children: kids };
  });
  return nodes.sort((a, b) => {
    const ad = a.children ? 0 : 1;
    const bd = b.children ? 0 : 1;
    return ad - bd || a.name.localeCompare(b.name);
  });
}

const STATUS_DOT: Record<DiffFile["status"], string> = {
  modified: "text-amber-400",
  added: "text-emerald-400",
  untracked: "text-emerald-400",
  deleted: "text-red-400",
  renamed: "text-sky-400",
};

function FileTree({
  files,
  collapsedDirs,
  onToggleDir,
  onPick,
}: {
  files: DiffFile[];
  collapsedDirs: Set<string>;
  onToggleDir: (path: string) => void;
  onPick: (path: string) => void;
}) {
  const tree = useMemo(() => buildFileTree(files), [files]);
  return (
    <ul className="select-none">
      {tree.map((node) => (
        <TreeRow
          key={node.path}
          node={node}
          depth={0}
          collapsedDirs={collapsedDirs}
          onToggleDir={onToggleDir}
          onPick={onPick}
        />
      ))}
    </ul>
  );
}

function TreeRow({
  node,
  depth,
  collapsedDirs,
  onToggleDir,
  onPick,
}: {
  node: TreeNode;
  depth: number;
  collapsedDirs: Set<string>;
  onToggleDir: (path: string) => void;
  onPick: (path: string) => void;
}) {
  const pad = { paddingLeft: `${depth * 12 + 4}px` };
  if (node.children) {
    const open = !collapsedDirs.has(node.path);
    return (
      <li>
        <button
          onClick={() => onToggleDir(node.path)}
          style={pad}
          className="flex w-full items-center gap-1 truncate py-0.5 text-left text-neutral-300 hover:text-neutral-100"
        >
          <span className="shrink-0 text-neutral-500">{open ? "▾" : "▸"}</span>
          <span className="truncate">{node.name}</span>
        </button>
        {open && (
          <ul>
            {node.children.map((child) => (
              <TreeRow
                key={child.path}
                node={child}
                depth={depth + 1}
                collapsedDirs={collapsedDirs}
                onToggleDir={onToggleDir}
                onPick={onPick}
              />
            ))}
          </ul>
        )}
      </li>
    );
  }
  return (
    <li>
      <button
        onClick={() => onPick(node.path)}
        style={pad}
        title={node.path}
        className="flex w-full items-center gap-1.5 truncate py-0.5 text-left hover:text-neutral-100"
      >
        <span className={`shrink-0 ${STATUS_DOT[node.file!.status]}`}>●</span>
        <span className="truncate text-neutral-300">{node.name}</span>
      </button>
    </li>
  );
}

function Centered({ children, tone }: { children: ReactNode; tone?: "error" }) {
  return (
    <div
      className={`flex h-full items-center justify-center p-6 text-sm ${tone === "error" ? "text-red-400" : "text-neutral-500"}`}
    >
      {children}
    </div>
  );
}
