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
	"github.com/sahil-shubham/karkhana/pkg/mission"
)

// Replayer is an optional source of historical events streamed
// to a newly-connected client BEFORE live bus events start. Used
// for the post-restart hydrate path: SQLite -> AllEventsForMissions.
// Implementations should return events ordered by id ascending.
type Replayer interface {
	ReplayEvents() ([]mission.Event, error)
}

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
// JSON lines. If `replayer` is non-nil, history is sent BEFORE
// the live stream starts so post-restart clients see the full
// timeline. Frontend dedupes by event.id so any overlap with
// live events is harmless.
func EventStreamHandler(bus *eventbus.Bus, replayer Replayer) http.HandlerFunc {
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

		// Subscribe BEFORE replay so live events that arrive
		// between the replay snapshot and the live loop don't
		// get dropped. Frontend dedupes by event.id; some
		// duplicates may be emitted, which is fine.
		ch, cancel := bus.Subscribe()
		defer cancel()

		if replayer != nil {
			history, err := replayer.ReplayEvents()
			if err != nil {
				slog.Warn("event replay failed (non-fatal)", "err", err)
			}
			for _, ev := range history {
				conn.SetWriteDeadline(time.Now().Add(writeWait))
				body, err := json.Marshal(ev)
				if err != nil {
					continue
				}
				if err := conn.WriteMessage(websocket.TextMessage, body); err != nil {
					slog.Debug("ws replay write failed", "err", err)
					return
				}
			}
			if n := len(history); n > 0 {
				slog.Info("canvas: replayed history", "events", n)
			}
		}

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
