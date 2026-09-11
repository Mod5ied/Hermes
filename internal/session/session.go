// Package session holds the in-memory conversation thread.
package session

import (
	"fmt"
	"strings"
	"sync"

	"github.com/hermes/hermes/internal/config"
	"github.com/hermes/hermes/internal/llm"
)

// Turn represents one user/assistant exchange.
type Turn struct {
	Instruction   string
	ImageDataURLs []string
	Answer        string
	AnswerType    llm.AnswerType
}

// Thread stores prior turns and builds context-aware message lists.
type Thread struct {
	mu           sync.Mutex
	turns        []Turn
	maxTurns     int
	imageWindow  int
	systemPrompt string
	manualPins   []int // user-pinned turn indices, cap 2
	autoPin      int   // index of most recent CODE answer, or -1
}

// NewThread creates a thread with the given context limits.
func NewThread(maxTurns, imageWindow int, systemPrompt string) *Thread {
	if maxTurns <= 0 {
		maxTurns = 4
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
		manualPins:   nil,
		autoPin:      -1,
	}
}

// VoiceReminder is appended to the current user turn to nudge the model toward
// a short, spoken, slightly imperfect voice. It is exported so tests can assert
// the exact message shape.
const VoiceReminder = "\n\nAnswer in a short, spoken, slightly imperfect voice. If this is a soft, opinion, or experience question, use one or two natural markers like 'kinda' or 'honestly'. If it is a hard fact, number, credential, definition, or code, stay clean and sure."

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

// effectivePinsLocked returns the effective pin indices, oldest-first, deduped,
// capped at 2. Manual pins are preferred over the auto-pin when over the cap.
func (t *Thread) effectivePinsLocked() []int {
	pins := validPins(t.manualPins, len(t.turns))
	if validPin(t.autoPin, len(t.turns)) && !containsPin(pins, t.autoPin) {
		pins = append(pins, t.autoPin)
	}
	if len(pins) > 2 {
		return pins[:2]
	}
	return pins
}

func validPins(candidates []int, turnCount int) []int {
	var pins []int
	for _, pin := range candidates {
		if validPin(pin, turnCount) {
			pins = append(pins, pin)
		}
	}
	return pins
}

func validPin(pin, turnCount int) bool { return pin >= 0 && pin < turnCount }

func containsPin(pins []int, target int) bool {
	for _, pin := range pins {
		if pin == target {
			return true
		}
	}
	return false
}

// TogglePin adds or removes a manual pin. It returns the new pinned state and
// false if adding would exceed the cap of 2.
func (t *Thread) TogglePin(i int) (pinned bool, ok bool) {
	t.mu.Lock()
	defer t.mu.Unlock()

	if i < 0 || i >= len(t.turns) {
		return false, false
	}

	if idx := pinIndex(t.manualPins, i); idx >= 0 {
		t.manualPins = append(t.manualPins[:idx], t.manualPins[idx+1:]...)
		return false, true
	}

	if len(t.effectivePinsLocked()) >= 2 {
		return false, false
	}
	t.manualPins = append(t.manualPins, i)
	return true, true
}

func pinIndex(pins []int, target int) int {
	for idx, pin := range pins {
		if pin == target {
			return idx
		}
	}
	return -1
}

// SetAutoPin records the most recent CODE-answer turn. Pass -1 to clear.
func (t *Thread) SetAutoPin(i int) {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.autoPin = i
}

// IsPinned reports whether index i is in the effective pin set.
func (t *Thread) IsPinned(i int) bool {
	t.mu.Lock()
	defer t.mu.Unlock()
	for _, p := range t.effectivePinsLocked() {
		if p == i {
			return true
		}
	}
	return false
}

// PinnedCount returns the size of the effective pin set (deduped, capped at 2).
func (t *Thread) PinnedCount() int {
	t.mu.Lock()
	defer t.mu.Unlock()
	return len(t.effectivePinsLocked())
}

// Build creates the message list for the current turn, including trimmed history.
// If vision is false, all image attachments are dropped.
func (t *Thread) Build(current Turn, vision bool) []llm.Message {
	return t.build(current, vision, "", false)
}

// BuildDocumentTask creates an accuracy-oriented request using a dedicated
// system prompt and the supplied document block. It intentionally omits the
// short spoken-voice reminder used by live interview mode.
func (t *Thread) BuildDocumentTask(current Turn, documents string, vision bool) []llm.Message {
	return t.build(current, vision, documents, true)
}

func (t *Thread) build(current Turn, vision bool, documents string, documentMode bool) []llm.Message {
	t.mu.Lock()
	defer t.mu.Unlock()

	pins := t.effectivePinsLocked()
	msgs := []llm.Message{t.systemMessage(pins, documentMode)}
	msgs = append(msgs, t.historyMessages(pins)...)
	return append(msgs, t.currentMessage(current, documents, vision, documentMode))
}

func (t *Thread) systemMessage(pins []int, documentMode bool) llm.Message {
	content := t.systemPrompt
	if documentMode {
		content = llm.DocumentTaskSystemPrompt()
	}
	if len(pins) > 0 {
		content += "\n\n" + buildReferenceBlock(t.turns, pins)
	}
	return llm.Message{Role: "system", Text: content}
}

func (t *Thread) historyMessages(pins []int) []llm.Message {
	pinSet := make(map[int]bool, len(pins))
	for _, pin := range pins {
		pinSet[pin] = true
	}
	start := max(0, len(t.turns)-t.maxTurns)
	var messages []llm.Message
	for i := start; i < len(t.turns); i++ {
		if !pinSet[i] {
			messages = append(messages, messagesForTurn(t.turns[i])...)
		}
	}
	return messages
}

func messagesForTurn(turn Turn) []llm.Message {
	userText := turn.Instruction
	if userText == "" {
		userText = "screenshot attached"
	}
	return []llm.Message{
		{Role: "user", Text: userText},
		{Role: "assistant", Text: turn.Answer},
	}
}

func (t *Thread) currentMessage(current Turn, documents string, vision, documentMode bool) llm.Message {
	if documentMode {
		return documentMessage(current, documents, t.recentImages(current, vision))
	}
	return realtimeMessage(current, t.recentImages(current, vision))
}

func documentMessage(current Turn, documents string, images []string) llm.Message {
	directions := current.Instruction
	if strings.TrimSpace(directions) == "" {
		directions = "Review the attached context carefully and return the most useful accurate result."
	}
	text := "<user_directions>\n" + directions + "\n</user_directions>\n\n<attached_context>\n" + documents + "</attached_context>"
	return llm.Message{Role: "user", Text: text, ImageDataURLs: images, Mode: llm.DocumentMode}
}

func realtimeMessage(current Turn, images []string) llm.Message {
	text := current.Instruction
	if text == "" && len(current.ImageDataURLs) > 0 {
		text = "Answer every question visible in the screenshot. Treat each numbered question as a short SENTENCE explanation; do not select a single option."
	}
	if text == "" {
		text = "screenshot attached"
	}
	return llm.Message{Role: "user", Text: text + VoiceReminder, ImageDataURLs: images, Mode: llm.RealtimeMode}
}

func (t *Thread) recentImages(current Turn, vision bool) []string {
	if !vision {
		return nil
	}
	images := append(t.previousImages(), current.ImageDataURLs...)
	if len(images) > t.imageWindow && t.imageWindow > 0 {
		images = images[len(images)-t.imageWindow:]
	}
	if len(images) > 5 {
		images = images[len(images)-5:]
	}
	return images
}

func (t *Thread) previousImages() []string {
	if t.imageWindow <= 0 || len(t.turns) == 0 {
		return nil
	}
	window := []string{}
	for i := len(t.turns) - 1; i >= 0 && len(window) < t.imageWindow-1; i-- {
		window = prependRecent(window, t.turns[i].ImageDataURLs, t.imageWindow-1)
	}
	return window
}

func prependRecent(window, candidates []string, limit int) []string {
	for j := len(candidates) - 1; j >= 0 && len(window) < limit; j-- {
		window = append([]string{candidates[j]}, window...)
	}
	return window
}

func buildReferenceBlock(turns []Turn, pins []int) string {
	var b strings.Builder
	b.WriteString("REFERENCE (pinned by the user). This is the canonical code or answer you are ")
	b.WriteString("iterating on. When the current question asks to change, extend, fix, or build on ")
	b.WriteString("it, modify this exact code and keep its names and structure. Do not rewrite it ")
	b.WriteString("from scratch or invent a different version. If the current question is unrelated, ")
	b.WriteString("ignore this section.")
	for n, idx := range pins {
		if idx < 0 || idx >= len(turns) {
			continue
		}
		q := turns[idx].Instruction
		if q == "" {
			q = "(problem shown in a screenshot)"
		}
		fmt.Fprintf(&b, "\n[%d] Question: %s\nAnswer:\n%s\n", n+1, q, turns[idx].Answer)
	}
	return b.String()
}

// Commit appends the completed current turn to the thread.
func (t *Thread) Commit(current Turn) {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.turns = append(t.turns, current)
}

// Clear wipes the thread and all pins.
func (t *Thread) Clear() {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.turns = t.turns[:0]
	t.manualPins = t.manualPins[:0]
	t.autoPin = -1
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
