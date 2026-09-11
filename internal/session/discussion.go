package session

import (
	"strings"

	"github.com/hermes/hermes/internal/llm"
)

// BuildDiscussionTask creates a document-grounded spoken response to the
// teammate's latest statement.
func (t *Thread) BuildDiscussionTask(current Turn, documents string) []llm.Message {
	return t.buildGroundedDiscussion(current, documents, llm.DiscussionSystemPrompt())
}

// BuildDiscussionQuestions creates two short questions grounded in the same
// discussion context.
func (t *Thread) BuildDiscussionQuestions(current Turn, documents string) []llm.Message {
	return t.buildGroundedDiscussion(current, documents, llm.DiscussionQuestionsSystemPrompt())
}

func (t *Thread) buildGroundedDiscussion(current Turn, documents, prompt string) []llm.Message {
	t.mu.Lock()
	defer t.mu.Unlock()
	pins := t.effectivePinsLocked()
	messages := []llm.Message{{Role: "system", Text: discussionPrompt(prompt, t.turns, pins)}}
	messages = append(messages, t.historyMessages(pins)...)
	return append(messages, discussionMessage(current, documents))
}

func discussionPrompt(prompt string, turns []Turn, pins []int) string {
	if len(pins) == 0 {
		return prompt
	}
	return prompt + "\n\n" + buildReferenceBlock(turns, pins)
}

func discussionMessage(current Turn, documents string) llm.Message {
	statement := strings.TrimSpace(current.Instruction)
	text := "<teammate_statement>\n" + statement + "\n</teammate_statement>\n\n<attached_context>\n" + documents + "</attached_context>"
	return llm.Message{Role: "user", Text: text, Mode: llm.DocumentMode}
}
