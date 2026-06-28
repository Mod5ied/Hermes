package llm

import (
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
)

func TestParseAnswer(t *testing.T) {
	cases := []struct {
		input string
		want  AnswerType
	}{
		{"Select B", Select},
		{"Select A and D", Select},
		{"No question detected", None},
		{"func main() {}", Code},
		{"This is a sentence answer.", Sentence},
	}

	for _, c := range cases {
		ans := ParseAnswer(c.input)
		assert.Equal(t, c.want, ans.Type, "input: %q", c.input)
		assert.Equal(t, strings.TrimSpace(c.input), ans.Text)
	}
}

func TestSystemPromptNoProfile(t *testing.T) {
	p := SystemPrompt("")
	assert.Contains(t, p, "none provided")
	assert.Contains(t, p, "CANDIDATE PROFILE")
	assert.NotContains(t, p, "{{PROFILE}}")
}

func TestSystemPromptWithProfile(t *testing.T) {
	p := SystemPrompt("Engineer with 5 years Go experience")
	assert.Contains(t, p, "Engineer with 5 years Go experience")
}
