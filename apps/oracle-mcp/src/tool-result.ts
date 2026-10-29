// The shape every MCP tool here answers in, and the wrapper that turns a thrown error
// into a result the model can read rather than a transport-level failure.

export type ToolResult = {
  content: { type: "text"; text: string }[];
  isError?: boolean;
};

export const ok = (text: string): ToolResult => ({ content: [{ type: "text", text }] });
export const fail = (message: string): ToolResult => ({
  content: [{ type: "text", text: message }],
  isError: true,
});

/** Wrap a tool body so any thrown error becomes a clean `isError` result the model
 *  can read, rather than a transport-level failure. */
export function tool<Args extends unknown[]>(
  run: (...args: Args) => Promise<ToolResult>,
): (...args: Args) => Promise<ToolResult> {
  return async (...args: Args) => {
    try {
      return await run(...args);
    } catch (e) {
      return fail(e instanceof Error ? e.message : String(e));
    }
  };
}
