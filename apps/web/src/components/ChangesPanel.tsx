import { useMemo, useState, type ReactNode } from "react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import {
  computeNewLineNumber,
  computeOldLineNumber,
  Diff,
  getChangeKey,
  Hunk,
  parseDiff,
  type ChangeData,
  type ChangeEventArgs,
} from "react-diff-view";
import { api, type NewComment } from "../lib/api.ts";
import type { CommentSide, DiffComment, DiffFile } from "../protocol.ts";

/** Where a pending/open comment composer is anchored. */
interface Anchor {
  file: string;
  changeKey: string;
  side: CommentSide;
  line: number;
}

/** Anchor a diff change to a (side, line): inserts/normals to new, deletes to old. */
function anchorOf(change: ChangeData): { side: CommentSide; line: number } {
  const n = computeNewLineNumber(change);
  if (n !== -1) return { side: "new", line: n };
  return { side: "old", line: computeOldLineNumber(change) };
}

const STATUS_STYLE: Record<DiffFile["status"], string> = {
  modified: "text-amber-400",
  added: "text-emerald-400",
  untracked: "text-emerald-400",
  deleted: "text-red-400",
  renamed: "text-sky-400",
};

export function ChangesPanel({ sessionId }: { sessionId: string }) {
  const qc = useQueryClient();
  const diff = useQuery({ queryKey: ["diff", sessionId], queryFn: () => api.diff(sessionId) });
  const comments = useQuery({ queryKey: ["comments", sessionId], queryFn: () => api.comments(sessionId) });
  const [active, setActive] = useState<Anchor | null>(null);

  const addMut = useMutation({
    mutationFn: (c: NewComment) => api.addComment(sessionId, c),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ["comments", sessionId] });
      setActive(null);
    },
  });
  const delMut = useMutation({
    mutationFn: (commentId: string) => api.deleteComment(sessionId, commentId),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["comments", sessionId] }),
  });

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
  if (files.length === 0) {
    return <Centered>No changes in the working tree.</Centered>;
  }

  const totals = files.reduce(
    (acc, f) => ({ add: acc.add + f.additions, del: acc.del + f.deletions }),
    { add: 0, del: 0 },
  );

  return (
    <div className="h-full overflow-y-auto bg-neutral-950">
      <div className="sticky top-0 z-10 flex items-center gap-3 border-b border-neutral-800 bg-neutral-950 px-4 py-2 text-xs text-neutral-400">
        <span>
          {files.length} file{files.length === 1 ? "" : "s"}
        </span>
        <span className="text-emerald-400">+{totals.add}</span>
        <span className="text-red-400">−{totals.del}</span>
        {diff.data?.truncatedFiles && <span className="text-amber-500">(list capped)</span>}
        <button
          onClick={() => {
            diff.refetch();
            comments.refetch();
          }}
          className="ml-auto rounded border border-neutral-700 px-2 py-0.5 hover:border-neutral-500 hover:text-neutral-200"
        >
          Refresh
        </button>
      </div>
      <div className="flex flex-col gap-4 p-4">
        {files.map((file) => (
          <FileCard
            key={file.path}
            file={file}
            comments={commentsByFile.get(file.path) ?? []}
            active={active}
            onStart={setActive}
            onCancel={() => setActive(null)}
            onSubmit={(c) => addMut.mutate(c)}
            onDelete={(id) => delMut.mutate(id)}
            submitting={addMut.isPending}
          />
        ))}
      </div>
    </div>
  );
}

interface FileCardProps {
  file: DiffFile;
  comments: DiffComment[];
  active: Anchor | null;
  onStart: (a: Anchor) => void;
  onCancel: () => void;
  onSubmit: (c: NewComment) => void;
  onDelete: (id: string) => void;
  submitting: boolean;
}

function FileCard({ file, comments, active, onStart, onCancel, onSubmit, onDelete, submitting }: FileCardProps) {
  const parsed = useMemo(() => (file.diff ? parseDiff(file.diff)[0] : undefined), [file.diff]);

  const widgets = useMemo(() => {
    if (!parsed) return {};
    // Map every (side:line) in this file's diff to its react-diff-view change key.
    const keyByAnchor = new Map<string, string>();
    for (const hunk of parsed.hunks) {
      for (const change of hunk.changes) {
        const a = anchorOf(change);
        keyByAnchor.set(`${a.side}:${a.line}`, getChangeKey(change));
      }
    }
    // Group existing comments by the change key their line resolves to.
    const grouped = new Map<string, DiffComment[]>();
    for (const c of comments) {
      const key = keyByAnchor.get(`${c.side}:${c.line}`);
      if (!key) continue; // line no longer present in the current diff
      const list = grouped.get(key);
      if (list) list.push(c);
      else grouped.set(key, [c]);
    }

    const keys = new Set(grouped.keys());
    if (active?.file === file.path) keys.add(active.changeKey);

    const result: Record<string, ReactNode> = {};
    for (const key of keys) {
      const list = grouped.get(key) ?? [];
      const isActive = active?.file === file.path && active.changeKey === key;
      result[key] = (
        <div className="border-y border-neutral-800 bg-neutral-900/60 px-4 py-2 text-sm">
          {list.map((c) => (
            <CommentItem key={c.id} comment={c} onDelete={() => onDelete(c.id)} />
          ))}
          {isActive ? (
            <Composer
              submitting={submitting}
              onCancel={onCancel}
              onSubmit={(body) => onSubmit({ file: file.path, side: active.side, line: active.line, body })}
            />
          ) : (
            list.length > 0 && (
              <button
                onClick={() =>
                  onStart({ file: file.path, changeKey: key, side: list[0]!.side, line: list[0]!.line })
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
    return result;
  }, [parsed, comments, active, file.path, submitting, onStart, onCancel, onSubmit, onDelete]);

  const onGutterClick = ({ change }: ChangeEventArgs) => {
    if (!change) return;
    const a = anchorOf(change);
    onStart({ file: file.path, changeKey: getChangeKey(change), side: a.side, line: a.line });
  };

  return (
    <div className="overflow-hidden rounded-md border border-neutral-800">
      <div className="flex items-center gap-2 border-b border-neutral-800 bg-neutral-900 px-3 py-1.5 font-mono text-xs">
        <span className={STATUS_STYLE[file.status]}>{file.status}</span>
        <span className="truncate text-neutral-300">
          {file.oldPath ? `${file.oldPath} → ${file.path}` : file.path}
        </span>
        <span className="ml-auto shrink-0 text-neutral-500">
          <span className="text-emerald-400">+{file.additions}</span>{" "}
          <span className="text-red-400">−{file.deletions}</span>
        </span>
      </div>
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
            widgets={widgets}
            gutterEvents={{ onClick: onGutterClick }}
          >
            {(hunks) => hunks.map((hunk) => <Hunk key={hunk.content} hunk={hunk} />)}
          </Diff>
        </div>
      ) : (
        <p className="px-3 py-2 text-xs text-neutral-500">No textual changes.</p>
      )}
    </div>
  );
}

function CommentItem({ comment, onDelete }: { comment: DiffComment; onDelete: () => void }) {
  return (
    <div className="group mb-1.5 rounded bg-neutral-800/60 px-2 py-1.5">
      <div className="flex items-start gap-2">
        <p className="min-w-0 flex-1 whitespace-pre-wrap break-words text-neutral-200">{comment.body}</p>
        <button
          onClick={onDelete}
          title="Delete comment"
          className="shrink-0 text-neutral-600 opacity-0 transition group-hover:opacity-100 hover:text-red-400"
        >
          ✕
        </button>
      </div>
      <time className="text-[10px] text-neutral-500">{new Date(comment.createdAt).toLocaleString()}</time>
    </div>
  );
}

function Composer({
  onSubmit,
  onCancel,
  submitting,
}: {
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
        <button onClick={onCancel} className="rounded px-2 py-0.5 text-xs text-neutral-400 hover:text-neutral-200">
          Cancel
        </button>
      </div>
    </div>
  );
}

function Centered({ children, tone }: { children: ReactNode; tone?: "error" }) {
  return (
    <div className={`flex h-full items-center justify-center p-6 text-sm ${tone === "error" ? "text-red-400" : "text-neutral-500"}`}>
      {children}
    </div>
  );
}
