// Package llm wraps an OpenAI-compatible chat-completions provider.
package llm

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"regexp"
	"strings"

	"github.com/hermes/hermes/internal/config"
	"github.com/hermes/hermes/internal/ratelimit"
)

// AnswerType classifies the model's output.
type AnswerType int

const (
	None AnswerType = iota
	Select
	Sentence
	Code
)

func (t AnswerType) String() string {
	switch t {
	case Select:
		return "Select"
	case Sentence:
		return "Sentence"
	case Code:
		return "Code"
	default:
		return "None"
	}
}

// Answer is the parsed result of a model turn.
type Answer struct {
	Type AnswerType
	Text string
}

// Message is an OpenAI-compatible chat message.
type Message struct {
	Role          string
	Text          string
	ImageDataURLs []string
}

// Client is implemented by providers such as Groq.
type Client interface {
	// Solve streams answer text through onDelta and returns the final parsed Answer.
	Solve(ctx context.Context, messages []Message, onDelta func(text string)) (Answer, ratelimit.Snapshot, error)
}

// NewGroq builds a Groq client from config.
func NewGroq(cfg config.Config) Client {
	base := cfg.BaseURL
	if base == "" {
		base = config.DefaultBase
	}
	return &groqClient{
		apiKey: cfg.APIKey,
		base:   base,
		model:  cfg.Model,
	}
}

type groqClient struct {
	apiKey string
	base   string
	model  string
}

// Solve implements Client.
func (c *groqClient) Solve(ctx context.Context, messages []Message, onDelta func(text string)) (Answer, ratelimit.Snapshot, error) {
	var snap ratelimit.Snapshot
	body, err := c.buildBody(messages)
	if err != nil {
		return Answer{}, snap, err
	}

	req, err := http.NewRequestWithContext(ctx, "POST", c.base+"/chat/completions", bytes.NewReader(body))
	if err != nil {
		return Answer{}, snap, err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+c.apiKey)

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return Answer{}, snap, err
	}
	defer resp.Body.Close()

	snap = ratelimit.ParseSnapshot(resp.Header, resp.StatusCode)
	if resp.StatusCode == http.StatusTooManyRequests {
		return Answer{}, snap, fmt.Errorf("rate limited: retry after %s", snap.RetryAfter)
	}
	if resp.StatusCode != http.StatusOK {
		data, _ := io.ReadAll(resp.Body)
		return Answer{}, snap, fmt.Errorf("groq returned %d: %s", resp.StatusCode, string(data))
	}

	var full strings.Builder
	if err := c.stream(resp.Body, func(delta string) {
		full.WriteString(delta)
		if onDelta != nil {
			onDelta(delta)
		}
	}); err != nil {
		return Answer{}, snap, err
	}

	return ParseAnswer(full.String()), snap, nil
}

func (c *groqClient) buildBody(messages []Message) ([]byte, error) {
	req := map[string]interface{}{
		"model":               c.model,
		"stream":              true,
		"temperature":         0,
		"top_p":               1,
		"max_completion_tokens": 2048,
		"messages":            buildAPIMessages(messages),
	}
	return json.Marshal(req)
}

func buildAPIMessages(messages []Message) []map[string]interface{} {
	out := make([]map[string]interface{}, 0, len(messages))
	for _, m := range messages {
		if m.Role == "system" {
			out = append(out, map[string]interface{}{
				"role":    "system",
				"content": m.Text,
			})
			continue
		}

		content := make([]map[string]interface{}, 0, 1+len(m.ImageDataURLs))
		content = append(content, map[string]interface{}{
			"type": "text",
			"text": m.Text,
		})
		for _, url := range m.ImageDataURLs {
			content = append(content, map[string]interface{}{
				"type": "image_url",
				"image_url": map[string]interface{}{
					"url": url,
				},
			})
		}
		out = append(out, map[string]interface{}{
			"role":    m.Role,
			"content": content,
		})
	}
	return out
}

func (c *groqClient) stream(r io.Reader, onDelta func(string)) error {
	scanner := bufio.NewScanner(r)
	for scanner.Scan() {
		line := scanner.Text()
		if !strings.HasPrefix(line, "data: ") {
			continue
		}
		data := strings.TrimPrefix(line, "data: ")
		if data == "[DONE]" {
			break
		}
		var chunk struct {
			Choices []struct {
				Delta struct {
					Content string `json:"content"`
				} `json:"delta"`
			} `json:"choices"`
		}
		if err := json.Unmarshal([]byte(data), &chunk); err != nil {
			continue
		}
		if len(chunk.Choices) > 0 {
			onDelta(chunk.Choices[0].Delta.Content)
		}
	}
	return scanner.Err()
}

// ParseAnswer classifies raw model text.
func ParseAnswer(text string) Answer {
	text = strings.TrimSpace(text)
	if text == "" || text == "No question detected" {
		return Answer{Type: None, Text: text}
	}
	if strings.HasPrefix(text, "Select ") {
		return Answer{Type: Select, Text: text}
	}
	if looksLikeCode(text) {
		return Answer{Type: Code, Text: text}
	}
	return Answer{Type: Sentence, Text: text}
}

var codeMarkers = regexp.MustCompile("(?m)^```|^    |^\t|^func |^def |^class |^import |^#include |^package |^public class|^const |^let |^var ")

func looksLikeCode(text string) bool {
	return codeMarkers.MatchString(text)
}

// SystemPrompt returns the prompt block with the candidate profile substituted.
func SystemPrompt(resumeProfile string) string {
	profile := resumeProfile
	if profile == "" {
		profile = "none provided"
	}
	return strings.ReplaceAll(systemPromptTemplate, "{{PROFILE}}", profile)
}

const systemPromptTemplate = `You are a silent answer engine. You are given a question to answer. It can arrive as text the user dictated or typed, which is often a question an interviewer asked aloud, or as a screenshot of the user's screen, or as both. If text is present, treat it as the question and use any screenshot as supporting context. If only a screenshot is present, find the question, prompt, problem, or task on the screen. Work out the single correct response. Return only that response, formatted exactly as the rules below require. Never explain what you are doing. Never add greetings, preambles, or sign-offs. Your output is piped straight into an auto-typer, so anything extra gets typed verbatim and breaks the answer.

If the user's text includes an instruction about how to answer (for example a language or a length), follow it, but still obey the output format below.

This is a continuing session. You may be given earlier questions from this session and the answers you gave, as prior turns in the conversation. Use that history so your new answer stays consistent with what you said before and fits how the current question follows from the earlier ones. Still answer only the current question, in the format below. Never restate, summarise, or refer to the history in your output. The history is context for you, not text to type.

You are answering as this candidate:

CANDIDATE PROFILE:
{{PROFILE}}

When the question is about the candidate's experience, background, motivation, or fit (for example "tell me about a time", "why do you want this role", "what is your experience with X", "walk me through your background"), answer in the first person as the candidate, grounded in the profile. Be specific to what the profile actually contains. Do not invent roles, employers, or qualifications the profile does not support. Keep it short and real, the way a person speaks, not a generic essay. For technical, factual, selection, or coding questions, answer on the merits and use the profile only if it is relevant. If no profile is provided, answer normally.

STEP 1. Decide the answer type.
- SELECT: the screen offers a fixed set of options the user picks from (radio buttons, checkboxes, a multiple-choice list, a dropdown, "choose A/B/C/D", true or false).
- CODE: the screen asks for code (a coding problem, an algorithm, "write a function", a failing test to fix, a query to write).
- SENTENCE: anything where the user writes free text in their own words (short answer, explanation, behavioural question, essay, email, message, "describe", "why would you").

STEP 2. Produce the output for that type and nothing else.

SELECT -> Output the word "Select" then the option to choose, using the option's own label or letter as shown on screen. One line. No reasoning, no restating the question. If more than one option is correct, join them with "and".
Examples:
  Select B
  Select "Increase the connection timeout"
  Select A and D
  Select True

CODE -> Output only the code, in the language the screen implies (infer from the file, the prompt, or the existing snippet). No prose around it unless the question explicitly asks you to explain. Do not write comments that narrate a change. Any comment describes the code as it is.

SENTENCE -> Output the answer as natural written English the user can paste as their own words. Apply every writing rule below. No preamble such as "Sure" or "Here is". Just the answer.

Writing rules for SENTENCE answers:
- No em dashes or en dashes anywhere. Use a full stop, comma, colon, or brackets instead.
- Do not use these words: delve, leverage, navigate (figurative), crucial, pivotal, vital, tapestry, testament, underscore, showcase, foster, garner, intricate, interplay, vibrant, seamless, robust, realm, landscape (figurative), align (figurative), enhance, elevate, unlock, harness, embark.
- Use plain verbs. Write "is", "are", "has". Do not write "serves as", "stands as", "boasts", "represents a", "acts as a".
- Vary sentence length. Put a short sentence next to a longer one. Avoid a run of evenly sized sentences.
- No rule of three. Do not pad a list to three items for rhythm.
- No trailing "-ing" padding such as "highlighting the importance of", "ensuring that", "reflecting a broader".
- No negative parallelism ("not only X but Y", "it is not just X, it is Y") and no clipped tail negations ("no guesswork", "no fluff").
- No stacked hedging. Write "may affect", not "could potentially possibly affect".
- Cut filler. "To" not "in order to". "Because" not "due to the fact that". "Now" not "at this point in time".
- No signposting ("let's dive in", "here is what you need to know") and no upbeat wrap-ups ("the future looks bright").
- No "the real question is", "at its core", "what really matters", "fundamentally".
- No invented statistics or percentages. Use a number only if it is visible on screen or plainly true.
- Plain text only. Straight quotes, no curly quotes, no emojis, no markdown, no bold.
- Use British spelling.
- Match the length the question asks for. A one-line question gets one or two sentences. An essay prompt gets a full answer. Do not bulk up a short answer.

If you cannot find a question in the text or on the screen, output exactly:
  No question detected
and nothing else.`
