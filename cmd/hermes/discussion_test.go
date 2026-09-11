package main

import (
	"testing"

	"github.com/hermes/hermes/internal/llm"
	"github.com/hermes/hermes/internal/session"
	"github.com/stretchr/testify/assert"
)

func TestDiscussionHistoryLimitKeepsLongConversation(t *testing.T) {
	assert.Equal(t, minimumDiscussionTurns, discussionHistoryLimit(12))
	assert.Equal(t, 64, discussionHistoryLimit(64))
}

func TestBuildMessagesSelectsDiscussionPrompt(t *testing.T) {
	thread := session.NewThread(48, 0, llm.DiscussionSystemPrompt())
	messages := buildMessages(thread, session.Turn{Instruction: "Explain that score"}, "document", false, true, true, false)
	assert.Equal(t, llm.DiscussionSystemPrompt(), messages[0].Text)
}

func TestBuildMessagesSelectsQuestionPrompt(t *testing.T) {
	thread := session.NewThread(48, 0, llm.DiscussionSystemPrompt())
	messages := buildMessages(thread, session.Turn{Instruction: "Maybe the score is harsh"}, "document", false, true, true, true)
	assert.Equal(t, llm.DiscussionQuestionsSystemPrompt(), messages[0].Text)
}

func TestNoSendInputRequiresStatementInDiscussion(t *testing.T) {
	assert.True(t, noSendInput("  ", 0, true, true))
	assert.False(t, noSendInput("Can you explain that?", 0, true, true))
}

func TestDiscussionModeMessageShowsGroundedState(t *testing.T) {
	assert.Contains(t, discussionModeMessage(true), "Discussion Mode on")
	assert.Equal(t, "Discussion Mode off", discussionModeMessage(false))
}
