// Package canvas is the server-side plumbing for the canvas UI.
// It exposes the WebSocket endpoint the React app subscribes to;
// every event published on the eventbus reaches every subscriber
// here as a JSON line.
package canvas

import (
	"encoding/json"
	"log/slog"
	"net/http"
	"time"

	"github.com/gorilla/websocket"

	"github.com/sahil-shubham/karkhana/pkg/eventbus"
)

const (
	writeWait      = 10 * time.Second
	pongWait       = 60 * time.Second
	pingPeriod     = (pongWait * 9) / 10
	maxMessageSize = 1 << 16 // 64 KB ought to be enough; we don't take large
	                          // messages from the browser today.
)

// upgrader allows any origin during development. Tighten for prod.
var upgrader = websocket.Upgrader{
	ReadBufferSize:  4096,
	WriteBufferSize: 4096,
	CheckOrigin:     func(r *http.Request) bool { return true },
}

// EventStreamHandler returns an http.HandlerFunc that subscribes
// each connecting client to the eventbus and streams events as
// JSON lines.
func EventStreamHandler(bus *eventbus.Bus) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		conn, err := upgrader.Upgrade(w, r, nil)
		if err != nil {
			slog.Warn("ws upgrade failed", "err", err)
			return
		}
		defer conn.Close()

		conn.SetReadLimit(maxMessageSize)
		conn.SetReadDeadline(time.Now().Add(pongWait))
		conn.SetPongHandler(func(string) error {
			conn.SetReadDeadline(time.Now().Add(pongWait))
			return nil
		})

		ch, cancel := bus.Subscribe()
		defer cancel()

		// Two goroutines: one reads from the bus and writes to the
		// socket; the other reads from the socket (so we can detect
		// close) and pings periodically.
		done := make(chan struct{})

		// Reader: detects browser-side close and consumes pings.
		go func() {
			defer close(done)
			for {
				if _, _, err := conn.ReadMessage(); err != nil {
					return
				}
			}
		}()

		ticker := time.NewTicker(pingPeriod)
		defer ticker.Stop()

		// Writer + ping loop.
		for {
			select {
			case event, ok := <-ch:
				if !ok {
					return
				}
				conn.SetWriteDeadline(time.Now().Add(writeWait))
				body, err := json.Marshal(event)
				if err != nil {
					slog.Warn("event marshal failed", "err", err)
					continue
				}
				if err := conn.WriteMessage(websocket.TextMessage, body); err != nil {
					slog.Debug("ws write failed; client likely gone", "err", err)
					return
				}

			case <-ticker.C:
				conn.SetWriteDeadline(time.Now().Add(writeWait))
				if err := conn.WriteMessage(websocket.PingMessage, nil); err != nil {
					return
				}

			case <-done:
				return

			case <-r.Context().Done():
				return
			}
		}
	}
}
