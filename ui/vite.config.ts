import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// https://vitejs.dev/config/
export default defineConfig({
  plugins: [react()],
  server: {
    port: 5173,
    proxy: {
      "/api": {
        target: "http://localhost:4000",
        changeOrigin: true,
        // WebSocket support for /api/events
        ws: true,
      },
      // KasmVNC proxy. Karkhana injects HTTP Basic auth and
      // forwards to the bhatti-published URL. WebSocket support
      // is critical — KasmVNC's RFB rides on Websockify over WS.
      "/proxy": {
        target: "http://localhost:4000",
        changeOrigin: true,
        ws: true,
      },
    },
  },
  build: {
    outDir: "dist",
    sourcemap: true,
  },
});
