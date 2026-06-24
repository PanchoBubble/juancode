import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";

const SERVER = "http://localhost:4280";

export default defineConfig({
  plugins: [react(), tailwindcss()],
  define: {
    // refractor@2 (CommonJS) references Node's `global`, absent in the browser
    global: "globalThis",
  },
  server: {
    port: 5280,
    open: true,
    proxy: {
      "/api": { target: SERVER, changeOrigin: true },
      "/ws": { target: SERVER, ws: true, changeOrigin: true },
    },
  },
});
