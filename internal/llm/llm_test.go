package llm

import (
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
)

func TestParseAnswer(t *testing.T) {
	cases := []struct {
		input     string
		wantType  AnswerType
		wantText  string
	}{
		{"Select B", Select, "Select B"},
		{"Select A and D", Select, "Select A and D"},
		{"No question detected", None, ""},
		{"func main() {}", Code, "func main() {}"},
		{"This is a sentence answer.", Sentence, "This is a sentence answer."},
	}

	for _, c := range cases {
		ans := ParseAnswer(c.input)
		assert.Equal(t, c.wantType, ans.Type, "input: %q", c.input)
		assert.Equal(t, c.wantText, ans.Text)
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

func TestOpenAIStreamIgnoresReasoningDeltas(t *testing.T) {
	body := "data: {\"choices\":[{\"delta\":{\"reasoning\":\"The user asks...\"}}]}\n\n" +
		"data: {\"choices\":[{\"delta\":{\"reasoning\":\". Should be concise...\"}}]}\n\n" +
		"data: {\"choices\":[{\"delta\":{\"content\":\"Hello!\"}}]}\n\n" +
		"data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}],\"usage\":{\"completion_tokens\":54,\"prompt_tokens\":87}}\n\n" +
		"data: [DONE]\n\n"

	client := &openAIClient{apiKey: "test", base: "http://unused", model: "gpt-oss-120b"}
	var got string
	err := client.stream(strings.NewReader(body), func(delta string) { got += delta })
	assert.NoError(t, err)
	assert.Equal(t, "Hello!", got)
	assert.NotContains(t, got, "reasoning")
}

func TestProxyStreamIgnoresReasoningDeltas(t *testing.T) {
	body := "data: {\"choices\":[{\"delta\":{\"reasoning\":\"The user asks...\"}}]}\n\n" +
		"data: {\"choices\":[{\"delta\":{\"reasoning\":\". Should be concise...\"}}]}\n\n" +
		"data: {\"choices\":[{\"delta\":{\"content\":\"Hello!\"}}]}\n\n" +
		"data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}],\"usage\":{\"completion_tokens\":54,\"prompt_tokens\":87}}\n\n" +
		"data: {\"hermes\":{\"balance_pct\":98}}\n\n" +
		"data: [DONE]\n\n"

	client := &proxyClient{workerURL: "http://unused", model: "gpt-oss-120b"}
	var full strings.Builder
	var got string
	err := client.stream(strings.NewReader(body), &full, func(delta string) { got += delta })
	assert.NoError(t, err)
	assert.Equal(t, "Hello!", got)
	assert.Equal(t, "Hello!", full.String())
	assert.NotContains(t, got, "reasoning")
	assert.NotContains(t, full.String(), "reasoning")
}
