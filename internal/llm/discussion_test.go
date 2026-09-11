package llm

import (
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
)

func TestNormalizeDiscussionQuestionsEnforcesTwoLabelledLines(t *testing.T) {
	answer := NormalizeDiscussionQuestions("Here are two options:\n- Q1: How should we explain the low faithfulness score?\n- Q2: What evidence would change your view?")
	assert.Equal(t, "Q1: How should we explain the low faithfulness score?\nQ2: What evidence would change your view?", answer.Text)
	assert.Equal(t, Sentence, answer.Type)
}

func TestNormalizeDiscussionQuestionsSplitsOneLine(t *testing.T) {
	answer := NormalizeDiscussionQuestions("How does that affect the commit message? What should we revise first?")
	assert.Equal(t, []string{
		"Q1: How does that affect the commit message?",
		"Q2: What should we revise first?",
	}, strings.Split(answer.Text, "\n"))
}

func TestNormalizeDiscussionQuestionsCapsQuestionLength(t *testing.T) {
	long := "Q1: How " + strings.Repeat("carefully ", 25) + "?\nQ2: What changed?"
	answer := NormalizeDiscussionQuestions(long)
	first := strings.Fields(strings.Split(answer.Text, "\n")[0])
	assert.LessOrEqual(t, len(first)-1, 18)
}

func TestDiscussionPromptForbidsAugmentingAttachedWork(t *testing.T) {
	prompt := DiscussionSystemPrompt()
	assert.Contains(t, prompt, "primary source of truth")
	assert.Contains(t, prompt, "Do not augment")
	assert.Contains(t, prompt, "explicit correction")
	assert.Contains(t, prompt, "two to four short")
}
