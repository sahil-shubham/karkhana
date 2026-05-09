// Package eventbus is a tiny in-process pub/sub for events flowing
// between Karkhana's internal goroutines and the canvas WebSocket.
//
// The pattern: a producer (mock event source today, real
// WorkerRunner tomorrow) calls bus.Publish(event); subscribers
// (the canvas WS handler, the persistence layer once Postgres
// lands) call bus.Subscribe() and receive a channel of events.
//
// Topic-filtered subscriptions are not implemented in v0; every
// subscriber gets every event and filters client-side. This is
// fine until traffic grows.
package eventbus

import (
	"sync"

	"github.com/sahil-shubham/karkhana/pkg/mission"
)

// Bus is the in-process broadcast hub. Safe for concurrent use.
type Bus struct {
	mu      sync.Mutex
	subs    map[chan mission.Event]struct{}
	closed  bool
}

// New creates an empty bus.
func New() *Bus {
	return &Bus{
		subs: make(map[chan mission.Event]struct{}),
	}
}

// Subscribe returns a channel that will receive every published
// event. The buffer is generous (256) so slow consumers don't
// drop frames during normal bursts; truly slow consumers will
// have events dropped (logged, eventually) rather than block the
// publisher.
//
// The returned cancel function unsubscribes and closes the channel.
func (b *Bus) Subscribe() (<-chan mission.Event, func()) {
	ch := make(chan mission.Event, 256)
	b.mu.Lock()
	if b.closed {
		b.mu.Unlock()
		close(ch)
		return ch, func() {}
	}
	b.subs[ch] = struct{}{}
	b.mu.Unlock()
	return ch, func() {
		b.mu.Lock()
		defer b.mu.Unlock()
		if _, ok := b.subs[ch]; ok {
			delete(b.subs, ch)
			close(ch)
		}
	}
}

// Publish broadcasts an event to all subscribers. Non-blocking;
// if a subscriber's buffer is full, the event is dropped *for
// that subscriber only*. The publisher never blocks.
func (b *Bus) Publish(e mission.Event) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.closed {
		return
	}
	for ch := range b.subs {
		select {
		case ch <- e:
		default:
			// subscriber too slow; drop and keep going.
			// once we have logging, log here.
		}
	}
}

// Close shuts down the bus and closes all subscriber channels.
func (b *Bus) Close() {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.closed = true
	for ch := range b.subs {
		close(ch)
	}
	b.subs = nil
}
