import type {
  BeadsResult,
  CommentSide,
  DiffComment,
  DiffResult,
  ProviderId,
  SessionMeta,
} from "../protocol.ts";

export interface ProviderInfo {
  id: ProviderId;
  label: string;
}

export interface DirEntry {
  name: string;
  path: string;
}

export interface DirListing {
  path: string;
  parent: string | null;
  entries: DirEntry[];
  /** True when `entries` are recursive search matches rather than direct children. */
  search: boolean;
}

async function getJson<T>(url: string): Promise<T> {
  const res = await fetch(url);
  if (!res.ok) throw new Error(`${res.status} ${res.statusText}`);
  return (await res.json()) as T;
}

async function sendJson<T>(url: string, method: string, body?: unknown): Promise<T> {
  const res = await fetch(url, {
    method,
    headers: body === undefined ? undefined : { "Content-Type": "application/json" },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  if (!res.ok) throw new Error(`${res.status} ${res.statusText}`);
  return (res.status === 204 ? undefined : await res.json()) as T;
}

export interface NewComment {
  file: string;
  side: CommentSide;
  line: number;
  body: string;
}

export const api = {
  providers: () => getJson<ProviderInfo[]>("/api/providers"),
  sessions: () => getJson<SessionMeta[]>("/api/sessions"),
  dirs: (path?: string, q?: string) => {
    const params = new URLSearchParams();
    if (path) params.set("path", path);
    if (q) params.set("q", q);
    const qs = params.toString();
    return getJson<DirListing>(`/api/dirs${qs ? `?${qs}` : ""}`);
  },
  diff: (id: string) => getJson<DiffResult>(`/api/sessions/${id}/diff`),
  beads: (id: string) => getJson<BeadsResult>(`/api/sessions/${id}/beads`),
  comments: (id: string) => getJson<DiffComment[]>(`/api/sessions/${id}/comments`),
  addComment: (id: string, c: NewComment) =>
    sendJson<DiffComment>(`/api/sessions/${id}/comments`, "POST", c),
  deleteComment: (id: string, commentId: string) =>
    sendJson<void>(`/api/sessions/${id}/comments/${commentId}`, "DELETE"),
};
