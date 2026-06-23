import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";

const SERVER = "http://localhost:4280";

export default defineConfig({
  plugins: [react(), tailwindcss()],
  server: {
    port: 5280,
    proxy: {
      "/api": { target: SERVER, changeOrigin: true },
      "/ws": { target: SERVER, ws: true, changeOrigin: true },
    },
  },
});
