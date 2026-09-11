package session

import (
	"strings"
	"testing"

	"github.com/hermes/hermes/internal/llm"
	"github.com/stretchr/testify/assert"
)

func TestBuildDiscussionTaskGroundsCurrentStatement(t *testing.T) {
	thread := NewThread(48, 0, "unused")
	messages := thread.BuildDiscussionTask(
		Turn{Instruction: "Why did you score Version B that low?", ImageDataURLs: []string{"ignored-screenshot"}},
		`<document name="form_answers.md">Faithfulness: 1</document>`,
	)

	assert.Equal(t, llm.DiscussionSystemPrompt(), messages[0].Text)
	last := messages[len(messages)-1]
	assert.Equal(t, llm.DocumentMode, last.Mode)
	assert.Contains(t, last.Text, "<teammate_statement>\nWhy did you score Version B that low?")
	assert.Contains(t, last.Text, "Faithfulness: 1")
	assert.Empty(t, last.ImageDataURLs)
}

func TestBuildDiscussionQuestionsUsesStrictQuestionPrompt(t *testing.T) {
	thread := NewThread(48, 0, "unused")
	messages := thread.BuildDiscussionQuestions(
		Turn{Instruction: "We may need to reconsider the unsupported claims."},
		`<document name="form_answers.md">Version B contains unsupported claims.</document>`,
	)

	assert.Equal(t, llm.DiscussionQuestionsSystemPrompt(), messages[0].Text)
	assert.Contains(t, messages[len(messages)-1].Text, "<teammate_statement>")
	assert.Contains(t, llm.DiscussionQuestionsSystemPrompt(), "Q1: How")
	assert.Contains(t, llm.DiscussionQuestionsSystemPrompt(), "exactly two")
}

func TestDiscussionHistoryPreservesAdjustments(t *testing.T) {
	thread := NewThread(48, 0, "unused")
	thread.Commit(Turn{Instruction: "Call this a minor omission.", Answer: "I treated it as a minor omission."})
	messages := thread.BuildDiscussionTask(Turn{Instruction: "Can you explain that?"}, "document")

	var text strings.Builder
	for _, message := range messages {
		text.WriteString(message.Text)
	}
	assert.Contains(t, text.String(), "Call this a minor omission.")
	assert.Contains(t, text.String(), "I treated it as a minor omission.")
}
