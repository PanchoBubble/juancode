import { useEffect, useState } from "react";
import { Outlet, useNavigate, useRouterState } from "@tanstack/react-router";
import { Sidebar } from "./Sidebar.tsx";
import { ConnectionBanner } from "./ConnectionBanner.tsx";
import { onTrackNotification } from "../lib/trackedPrs.ts";
import { notifications } from "../lib/notifications.ts";

/**
 * Responsive app shell. On desktop the sidebar is a static column (unchanged
 * from before). On small screens it collapses into a slide-in drawer toggled by
 * a hamburger in a slim top bar, so sessions are controllable from a phone.
 */
export function AppShell() {
  const [drawerOpen, setDrawerOpen] = useState(false);
  const navigate = useNavigate();

  // Close the drawer whenever the route changes (e.g. tapping a session).
  const pathname = useRouterState({ select: (s) => s.location.pathname });
  useEffect(() => {
    setDrawerOpen(false);
  }, [pathname]);

  // Deep-link: tapping a session OS notification jumps straight to that session
  // (and thus its decision affordance when it's waiting on input). Track-PR
  // notifications use a `track-*` tag with no session route, so those are ignored.
  useEffect(() => {
    const onClick = (e: Event) => {
      const id = (e as CustomEvent<{ sessionId: string }>).detail?.sessionId;
      if (!id || id.startsWith("track-")) return;
      void navigate({ to: "/session/$id", params: { id } });
    };
    window.addEventListener("juancode:notification-click", onClick);
    return () => window.removeEventListener("juancode:notification-click", onClick);
  }, [navigate]);

  // Alert on tracked-PR needs-decision escalations (juancode-bt2): the same
  // urgent ding + (backgrounded-tab) OS notification used for "session needs
  // input", since a tracked PR raising a decision likewise wants the user.
  useEffect(() => {
    return onTrackNotification(({ prNumber, message }) =>
      notifications.fire("waiting_input", `PR #${prNumber}: ${message}`, `track-${prNumber}`),
    );
  }, []);

  // Close on Escape for keyboard users.
  useEffect(() => {
    if (!drawerOpen) return;
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") setDrawerOpen(false);
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [drawerOpen]);

  return (
    <div className="flex h-full w-full overflow-hidden">
      <ConnectionBanner />
      {/* Desktop sidebar: static column. Hidden on small screens. */}
      <div className="hidden md:flex">
        <Sidebar />
      </div>

      {/* Mobile drawer: off-canvas sidebar + backdrop, only mounted/visible < md. */}
      <div className="md:hidden">
        {drawerOpen && (
          <button
            type="button"
            aria-label="Close menu"
            onClick={() => setDrawerOpen(false)}
            className="fixed inset-0 z-30 bg-black/50"
          />
        )}
        <div
          className={`fixed inset-y-0 left-0 z-40 transition-transform duration-200 ${
            drawerOpen ? "translate-x-0" : "-translate-x-full"
          }`}
        >
          <Sidebar onNavigate={() => setDrawerOpen(false)} />
        </div>
      </div>

      <main className="flex min-w-0 flex-1 flex-col">
        {/* Mobile top bar with the drawer toggle. Hidden on desktop. */}
        <header className="flex shrink-0 items-center gap-2 border-b border-neutral-800 px-3 py-2 md:hidden">
          <button
            type="button"
            aria-label="Open menu"
            onClick={() => setDrawerOpen(true)}
            className="rounded-md px-2 py-1 text-lg leading-none text-neutral-300 hover:bg-neutral-800"
          >
            ☰
          </button>
          <span className="text-sm font-semibold tracking-tight">juancode</span>
        </header>
        <div className="min-h-0 flex-1">
          <Outlet />
        </div>
      </main>
    </div>
  );
}
