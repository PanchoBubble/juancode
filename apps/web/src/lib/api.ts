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
}

async function getJson<T>(url: string): Promise<T> {
  const res = await fetch(url);
  if (!res.ok) throw new Error(`${res.status} ${res.statusText}`);
  return (await res.json()) as T;
}

export const api = {
  providers: () => getJson<ProviderInfo[]>("/api/providers"),
  sessions: () => getJson<SessionMeta[]>("/api/sessions"),
  dirs: (path?: string) =>
    getJson<DirListing>(`/api/dirs${path ? `?path=${encodeURIComponent(path)}` : ""}`),
};
