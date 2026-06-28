// Package session holds the in-memory conversation thread.
package session

import (
	"sync"

	"github.com/hermes/hermes/internal/config"
	"github.com/hermes/hermes/internal/llm"
)

// Turn represents one user/assistant exchange.
type Turn struct {
	Instruction   string
	ImageDataURLs []string
	Answer        string
}

// Thread stores prior turns and builds context-aware message lists.
type Thread struct {
	mu           sync.Mutex
	turns        []Turn
	maxTurns     int
	imageWindow  int
	systemPrompt string
}

// NewThread creates a thread with the given context limits.
func NewThread(maxTurns, imageWindow int, systemPrompt string) *Thread {
	if maxTurns <= 0 {
		maxTurns = 12
	}
	if imageWindow < 0 {
		imageWindow = 0
	}
	if imageWindow > 5 {
		imageWindow = 5
	}
	return &Thread{
		maxTurns:     maxTurns,
		imageWindow:  imageWindow,
		systemPrompt: systemPrompt,
	}
}

// NewThreadFromConfig builds a thread using config values.
func NewThreadFromConfig(cfg config.Config) *Thread {
	return NewThread(cfg.ContextTurns, cfg.ImageWindow, llm.SystemPrompt(cfg.ResumeProfile))
}

// SystemPrompt returns the system prompt used by the thread.
func (t *Thread) SystemPrompt() string {
	t.mu.Lock()
	defer t.mu.Unlock()
	return t.systemPrompt
}

// Build creates the message list for the current turn, including trimmed history.
func (t *Thread) Build(current Turn) []llm.Message {
	t.mu.Lock()
	defer t.mu.Unlock()

	var msgs []llm.Message
	msgs = append(msgs, llm.Message{Role: "system", Text: t.systemPrompt})

	// Trim oldest turns if over budget.
	start := 0
	if len(t.turns) > t.maxTurns {
		start = len(t.turns) - t.maxTurns
	}

	for _, turn := range t.turns[start:] {
		userText := turn.Instruction
		if userText == "" {
			userText = "screenshot attached"
		}
		msgs = append(msgs, llm.Message{
			Role: "user",
			Text: userText,
		})
		msgs = append(msgs, llm.Message{
			Role: "assistant",
			Text: turn.Answer,
		})
	}

	// Current turn: include the image window of most recent screenshots.
	var images []string
	if t.imageWindow > 0 && len(t.turns) > 0 {
		// Include recent images from history up to imageWindow-1, then current turn's images.
		window := []string{}
		for i := len(t.turns) - 1; i >= 0 && len(window) < t.imageWindow-1; i-- {
			for j := len(t.turns[i].ImageDataURLs) - 1; j >= 0 && len(window) < t.imageWindow-1; j-- {
				window = append([]string{t.turns[i].ImageDataURLs[j]}, window...)
			}
		}
		// Append current turn images, then prepend historical window.
		images = append(window, current.ImageDataURLs...)
		if len(images) > t.imageWindow {
			images = images[len(images)-t.imageWindow:]
		}
	} else {
		images = current.ImageDataURLs
	}
	if len(images) > 5 {
		images = images[len(images)-5:]
	}

	currentText := current.Instruction
	if currentText == "" {
		if len(current.ImageDataURLs) > 0 {
			currentText = "Answer every question visible in the screenshot. Treat each numbered question as a short SENTENCE explanation; do not select a single option."
		} else {
			currentText = "screenshot attached"
		}
	}
	msgs = append(msgs, llm.Message{
		Role:          "user",
		Text:          currentText,
		ImageDataURLs: images,
	})

	return msgs
}

// Commit appends the completed current turn to the thread.
func (t *Thread) Commit(current Turn) {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.turns = append(t.turns, current)
}

// Clear wipes the thread.
func (t *Thread) Clear() {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.turns = t.turns[:0]
}

// Len returns the number of completed turns.
func (t *Thread) Len() int {
	t.mu.Lock()
	defer t.mu.Unlock()
	return len(t.turns)
}

// Turns returns a snapshot of completed turns, oldest first.
func (t *Thread) Turns() []Turn {
	t.mu.Lock()
	defer t.mu.Unlock()
	out := make([]Turn, len(t.turns))
	copy(out, t.turns)
	return out
}
