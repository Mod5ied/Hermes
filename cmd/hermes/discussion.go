package main

import (
	"strings"

	"github.com/hermes/hermes/internal/llm"
)

const minimumDiscussionTurns = 48

func discussionHistoryLimit(configured int) int {
	return max(configured, minimumDiscussionTurns)
}

func (a *application) toggleDiscussionMode() {
	a.setDiscussionMode(!a.discussionMode)
	a.overlay.Flash(discussionModeMessage(a.discussionMode))
}

func (a *application) askQuestions() {
	if !a.hasDocumentContext() {
		a.overlay.Flash("Attach document context before asking discussion questions")
		return
	}
	if strings.TrimSpace(a.overlay.Instruction()) == "" {
		a.overlay.Flash("Listen to or enter the teammate's current statement first")
		return
	}
	a.setDiscussionMode(true)
	a.questionRequest = true
	defer func() { a.questionRequest = false }()
	a.doSend()
}

func (a *application) hasDocumentContext() bool {
	return a.documents.Summary().Count > 0
}

func (a *application) setDiscussionMode(enabled bool) {
	a.discussionMode = enabled
	a.overlay.SetDiscussionMode(enabled)
	a.selectedHistory = -1
	a.overlay.ExitHistory()
	thread := a.activeThread()
	a.overlay.SetAnswerCount(thread.Len())
	a.overlay.SetPinnedBadge(thread.PinnedCount())
}

func discussionModeMessage(enabled bool) string {
	if enabled {
		return "Discussion Mode on: answers stay grounded in attached context"
	}
	return "Discussion Mode off"
}

func answerForRequest(request sendRequest, answer llm.Answer) llm.Answer {
	if request.questions {
		return llm.NormalizeDiscussionQuestions(answer.Text)
	}
	return answer
}

func (a *application) deltaHandler(request sendRequest) func(string) {
	if request.questions {
		return nil
	}
	return a.overlay.AppendAnswer
}
