import { useSyncExternalStore } from "react";

/**
 * Subscribe a component to a CSS media query, re-rendering when it flips. Used to
 * pick the phone-friendly live view over the desktop xterm (see SessionView).
 * SSR-safe: reports `false` until hydrated.
 */
export function useMediaQuery(query: string): boolean {
  return useSyncExternalStore(
    (cb) => {
      if (typeof window === "undefined") return () => {};
      const mql = window.matchMedia(query);
      mql.addEventListener("change", cb);
      return () => mql.removeEventListener("change", cb);
    },
    () => (typeof window === "undefined" ? false : window.matchMedia(query).matches),
    () => false,
  );
}

/** True on phone-width viewports (below Tailwind's `md` breakpoint). */
export function useIsPhone(): boolean {
  return useMediaQuery("(max-width: 767px)");
}
