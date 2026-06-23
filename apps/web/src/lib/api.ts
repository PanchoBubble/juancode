import type { ProviderId, SessionMeta } from "../protocol.ts";

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
};
