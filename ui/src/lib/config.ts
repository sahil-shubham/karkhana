// Origin / URL helpers.
//
// In Vite dev mode (`npm run dev`), the React app runs on :5173
// and the Karkhana API runs on :4000. Vite's dev-proxy ws: true
// is unreliable for the routes we use (/api/events streams, the
// kasmproxy /proxy/* WebSocket upgrade), so we connect directly
// to :4000 instead. CORS on Karkhana is permissive (`*`) so this
// works even though it's cross-origin from the browser's POV.
//
// In production (`make build`), the Karkhana binary embeds the
// built React bundle and serves it from the same :4000 origin —
// so apiBase / wsBase return empty/same-origin and everything is
// a relative URL.
//
// One env var lets you override:  VITE_KARKHANA_API="http://X:Y".

const ENV_API = import.meta.env.VITE_KARKHANA_API as string | undefined;

/** Absolute origin of the Karkhana HTTP API, no trailing slash. */
export const apiOrigin = (): string => {
  if (ENV_API) return ENV_API.replace(/\/$/, "");
  if (import.meta.env.DEV) return "http://localhost:4000";
  return ""; // same-origin in production
};

/** Absolute origin of the Karkhana WebSocket endpoints. */
export const wsOrigin = (): string => {
  const api = apiOrigin();
  if (api) {
    return api.replace(/^http/, "ws");
  }
  // same-origin: derive from current location
  return (location.protocol === "https:" ? "wss://" : "ws://") + location.host;
};

/** Build an absolute API URL from a path like "/api/missions". */
export const apiURL = (path: string): string => apiOrigin() + path;

/** Build an absolute WS URL from a path like "/api/events". */
export const wsURL = (path: string): string => wsOrigin() + path;
