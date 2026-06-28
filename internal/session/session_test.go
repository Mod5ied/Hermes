package session

import (
	"testing"

	"github.com/hermes/hermes/internal/llm"
	"github.com/stretchr/testify/assert"
)

func TestBuildHistory(t *testing.T) {
	th := NewThread(12, 1, "system")
	th.Commit(Turn{Instruction: "q1", Answer: "a1"})
	th.Commit(Turn{Instruction: "q2", Answer: "a2"})

	msgs := th.Build(Turn{Instruction: "q3"})
	assert.Equal(t, 6, len(msgs)) // system + 2*(user+assistant) + current
	assert.Equal(t, "system", msgs[0].Role)
	assert.Equal(t, "assistant", msgs[2].Role)
	assert.Equal(t, "q3", msgs[5].Text)
}

func TestMaxTurnsTrim(t *testing.T) {
	th := NewThread(2, 1, "system")
	th.Commit(Turn{Instruction: "q1", Answer: "a1"})
	th.Commit(Turn{Instruction: "q2", Answer: "a2"})
	th.Commit(Turn{Instruction: "q3", Answer: "a3"})

	msgs := th.Build(Turn{Instruction: "q4"})
	// system + 2*(user+assistant) + current = 6
	assert.Equal(t, 6, len(msgs))
	assert.Equal(t, "q2", msgs[1].Text)
}

func TestImageWindow(t *testing.T) {
	th := NewThread(12, 2, "system")
	th.Commit(Turn{Instruction: "q1", Answer: "a1", ImageDataURLs: []string{"old1"}})

	msgs := th.Build(Turn{Instruction: "q2", ImageDataURLs: []string{"new1"}})
	last := msgs[len(msgs)-1]
	assert.Equal(t, []string{"old1", "new1"}, last.ImageDataURLs)
}

func TestEmptyInstructionPlaceholder(t *testing.T) {
	th := NewThread(12, 1, llm.SystemPrompt(""))
	msgs := th.Build(Turn{ImageDataURLs: []string{"img"}})
	last := msgs[len(msgs)-1]
	assert.Equal(t, "screen shown", last.Text)
}
