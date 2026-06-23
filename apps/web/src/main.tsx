import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import {
  createRootRoute,
  createRoute,
  createRouter,
  Outlet,
  RouterProvider,
} from "@tanstack/react-router";
import { Sidebar } from "./components/Sidebar.tsx";
import { NewSession } from "./components/NewSession.tsx";
import { SessionView } from "./components/SessionView.tsx";
import "./styles.css";

const queryClient = new QueryClient();

const rootRoute = createRootRoute({
  component: () => (
    <div className="flex h-full w-full">
      <Sidebar />
      <main className="min-w-0 flex-1">
        <Outlet />
      </main>
    </div>
  ),
});

const indexRoute = createRoute({
  getParentRoute: () => rootRoute,
  path: "/",
  component: NewSession,
});

const sessionRoute = createRoute({
  getParentRoute: () => rootRoute,
  path: "/session/$id",
  component: function SessionRoute() {
    const { id } = sessionRoute.useParams();
    return <SessionView id={id} />;
  },
});

const routeTree = rootRoute.addChildren([indexRoute, sessionRoute]);
const router = createRouter({ routeTree });

declare module "@tanstack/react-router" {
  interface Register {
    router: typeof router;
  }
}

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <QueryClientProvider client={queryClient}>
      <RouterProvider router={router} />
    </QueryClientProvider>
  </StrictMode>,
);
