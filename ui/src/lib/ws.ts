// WebSocket client to /api/events with auto-reconnect.
//
// Calls onEvent for every line the server sends. Calls
// onConnState whenever the connection state changes so the UI
// can show a banner when disconnected.
//
// Usage:
//   const ws = connectEvents({ onEvent: (e) => ..., onConnState });
//   ...
//   ws.close();

import type { KEvent } from "./types";
import { wsURL } from "./config";

export type ConnState = "connecting" | "open" | "closed" | "error";

interface Options {
  onEvent: (event: KEvent) => void;
  onConnState?: (state: ConnState) => void;
  url?: string;
}

export function connectEvents(opts: Options) {
  const url = opts.url ?? wsURL("/api/events");

  let ws: WebSocket | null = null;
  let closed = false;
  let backoffMs = 500;

  const setState = (s: ConnState) => opts.onConnState?.(s);

  const open = () => {
    if (closed) return;
    setState("connecting");
    ws = new WebSocket(url);
    ws.onopen = () => {
      backoffMs = 500;
      setState("open");
    };
    ws.onmessage = (m) => {
      try {
        const event = JSON.parse(m.data) as KEvent;
        opts.onEvent(event);
      } catch (e) {
        console.warn("event parse failed", e, m.data);
      }
    };
    ws.onerror = () => setState("error");
    ws.onclose = () => {
      setState("closed");
      if (!closed) {
        const delay = backoffMs;
        backoffMs = Math.min(backoffMs * 2, 8000);
        setTimeout(open, delay);
      }
    };
  };

  open();

  return {
    close: () => {
      closed = true;
      ws?.close();
    },
  };
}
