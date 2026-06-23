/** Append `chunk` to `buffer`, keeping at most `limit` trailing characters. */
export function appendScrollback(buffer: string, chunk: string, limit: number): string {
  const next = buffer + chunk;
  return next.length > limit ? next.slice(next.length - limit) : next;
}
