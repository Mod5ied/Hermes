// Package tray holds the current turn's queued screenshots in memory.
package tray

import (
	"errors"
	"sync"
)

const MaxShots = 5

// Tray stores up to MaxShots base64 data URLs for the current turn.
type Tray struct {
	mu    sync.Mutex
	shots []string
}

// New creates an empty Tray.
func New() *Tray {
	return &Tray{shots: make([]string, 0, MaxShots)}
}

// Add appends a data URL to the tray. If the tray is full, the oldest shot is
// dropped. Returns the new count.
func (t *Tray) Add(dataURL string) (int, error) {
	if dataURL == "" {
		return 0, errors.New("empty data URL")
	}
	t.mu.Lock()
	defer t.mu.Unlock()

	if len(t.shots) >= MaxShots {
		t.shots = t.shots[1:]
	}
	t.shots = append(t.shots, dataURL)
	return len(t.shots), nil
}

// Shots returns the queued data URLs in insertion order.
func (t *Tray) Shots() []string {
	t.mu.Lock()
	defer t.mu.Unlock()
	out := make([]string, len(t.shots))
	copy(out, t.shots)
	return out
}

// Count returns the number of queued shots.
func (t *Tray) Count() int {
	t.mu.Lock()
	defer t.mu.Unlock()
	return len(t.shots)
}

// Clear empties the tray.
func (t *Tray) Clear() {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.shots = t.shots[:0]
}
