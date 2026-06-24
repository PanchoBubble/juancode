import { useEffect, useState, type ReactNode } from "react";
import { useQuery } from "@tanstack/react-query";
import { useNavigate } from "@tanstack/react-router";
import { api } from "../lib/api.ts";
import type { SearchHit } from "../lib/api.ts";

/**
 * Render a search snippet, turning the server's `[term]` markers into <mark>
 * highlights. The query already wraps matched terms in square brackets; here we
 * split on those and bold the inner runs.
 */
function renderSnippet(snippet: string): ReactNode[] {
  const parts: ReactNode[] = [];
  const re = /\[([^\]]*)\]/g;
  let last = 0;
  let m: RegExpExecArray | null;
  let key = 0;
  while ((m = re.exec(snippet)) !== null) {
    if (m.index > last) parts.push(snippet.slice(last, m.index));
    parts.push(
      <mark key={key++} className="rounded-sm bg-amber-400/20 text-amber-200">
        {m[1]}
      </mark>,
    );
    last = m.index + m[0].length;
  }
  if (last < snippet.length) parts.push(snippet.slice(last));
  return parts;
}

/**
 * Full-text search over session transcripts. Debounces the query, hits
 * `/api/search`, and lists matching sessions with a highlighted snippet of the
 * matched scrollback. Clicking a result opens that session.
 */
export function SearchPanel({ query }: { query: string }) {
  const navigate = useNavigate();
  const q = query.trim();

  // Debounce so we don't fire a request per keystroke.
  const [debounced, setDebounced] = useState(q);
  useEffect(() => {
    const t = setTimeout(() => setDebounced(q), 200);
    return () => clearTimeout(t);
  }, [q]);

  const enabled = debounced.length >= 2;
  const results = useQuery({
    queryKey: ["search", debounced],
    queryFn: () => api.search(debounced),
    enabled,
  });

  if (!enabled) return null;

  const hits: SearchHit[] = results.data ?? [];

  return (
    <div className="border-b border-neutral-900 px-2 py-2">
      <p className="px-2 pb-1 text-[10px] font-medium tracking-wide text-neutral-500 uppercase">
        Transcript search
      </p>
      {results.isLoading && <p className="px-2 py-1 text-xs text-neutral-500">Searching…</p>}
      {results.isError && (
        <p className="px-2 py-1 text-xs text-red-400">Search failed.</p>
      )}
      {!results.isLoading && !results.isError && hits.length === 0 && (
        <p className="px-2 py-1 text-xs text-neutral-500">No transcript matches.</p>
      )}
      <ul className="flex flex-col gap-0.5">
        {hits.map((h) => (
          <li key={h.id}>
            <button
              type="button"
              onClick={() => void navigate({ to: "/session/$id", params: { id: h.id } })}
              className="block w-full rounded-md px-2 py-1.5 text-left hover:bg-neutral-900"
              title={h.cwd}
            >
              <div className="flex items-center gap-2">
                <span className="truncate text-sm text-neutral-200">{h.title}</span>
                <span className="ml-auto shrink-0 text-[10px] text-neutral-500">{h.provider}</span>
              </div>
              {h.snippet && (
                <p className="mt-0.5 line-clamp-2 font-mono text-[11px] break-all whitespace-pre-wrap text-neutral-400">
                  {renderSnippet(h.snippet)}
                </p>
              )}
            </button>
          </li>
        ))}
      </ul>
    </div>
  );
}
