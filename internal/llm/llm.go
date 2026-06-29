// Package llm wraps an OpenAI-compatible chat-completions provider.
package llm

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
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
	return &openAIClient{
		apiKey: cfg.APIKey,
		base:   base,
		model:  cfg.Model,
	}
}

// NewCerebras builds a Cerebras client from config.
func NewCerebras(cfg config.Config) Client {
	base := cfg.BaseURL
	if base == "" {
		base = "https://api.cerebras.ai/v1"
	}
	return &openAIClient{
		apiKey: cfg.APIKey,
		base:   base,
		model:  cfg.Model,
	}
}

type openAIClient struct {
	apiKey string
	base   string
	model  string
}

// Solve implements Client.
func (c *openAIClient) Solve(ctx context.Context, messages []Message, onDelta func(text string)) (Answer, ratelimit.Snapshot, error) {
	var snap ratelimit.Snapshot
	body, err := c.buildBody(messages)
	if err != nil {
		return Answer{}, snap, err
	}

	// Diagnostic: log the shape of every request without exposing the API key.
	totalImages := 0
	for _, m := range messages {
		totalImages += len(m.ImageDataURLs)
	}
	if len(messages) > 0 {
		log.Printf("Hermes: Solve request turns=%d lastTextLen=%d images=%d",
			len(messages), len(messages[len(messages)-1].Text), totalImages)
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
		return Answer{}, snap, fmt.Errorf("provider returned %d: %s", resp.StatusCode, string(data))
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

func (c *openAIClient) buildBody(messages []Message) ([]byte, error) {
	req := map[string]interface{}{
		"model":               c.model,
		"stream":              true,
		"temperature":         0,
		"top_p":               1,
		"max_completion_tokens": 1024,
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

func (c *openAIClient) stream(r io.Reader, onDelta func(string)) error {
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
		return Answer{Type: None, Text: ""}
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

const systemPromptTemplate = `You are a silent answer engine. You are given a question to answer. It can arrive as text the user dictated or typed, which is often a question an interviewer asked aloud, or as a screenshot of the user's screen, or as both. If text is present, treat it as the question and use any screenshot as supporting context. If only a screenshot is present, find the question, prompt, problem, or task on the screen. Work out the correct response(s). If the screen contains multiple distinct questions, answer each one briefly. Return only that response, formatted exactly as the rules below require. Never explain what you are doing. Never add greetings, preambles, or sign-offs. Your output is piped straight into an auto-typer, so anything extra gets typed verbatim and breaks the answer.

If the user's text includes an instruction about how to answer (for example a language or a length), follow it, but still obey the output format below.

This is a continuing session. You may be given earlier questions from this session and the answers you gave, as prior turns in the conversation. Use that history so your new answer stays consistent with what you said before and fits how the current question follows from the earlier ones. Still answer only the current question, in the format below. Never restate, summarise, or refer to the history in your output. The history is context for you, not text to type.

You are answering as this candidate:

CANDIDATE PROFILE:
{{PROFILE}}

When the question is about the candidate's experience, background, motivation, or fit (for example "tell me about a time", "why do you want this role", "what is your experience with X", "walk me through your background"), answer in the first person as the candidate, grounded in the profile. Be specific to what the profile actually contains. Do not invent roles, employers, or qualifications the profile does not support. Keep it short and real, the way a person speaks, not a generic essay. For technical, factual, selection, or coding questions, answer on the merits and use the profile only if it is relevant. If no profile is provided, answer normally.

STEP 1. Decide the answer type.
- SELECT: the screen offers a fixed set of options the user picks from (radio buttons, checkboxes, a multiple-choice list with labelled A/B/C/D options, a dropdown, "choose X/Y/Z", true or false). A plain numbered list of questions without selectable options is NOT a SELECT question; treat it as SENTENCE.
- CODE: the screen asks for code (a coding problem, an algorithm, "write a function", a failing test to fix, a query to write).
- SENTENCE: anything where the user writes free text in their own words (short answer, explanation, behavioural question, essay, email, message, "describe", "why would you", a list of numbered questions).

STEP 2. Produce the output for that type and nothing else.

SELECT -> Output the word "Select" then the option to choose, using the option's own label or letter as shown on screen. One line. No reasoning, no restating the question. If more than one option is correct, join them with "and".
Examples:
  Select B
  Select "Increase the connection timeout"
  Select A and D
  Select True

CODE -> Output only the code, in the language the screen implies (infer from the file, the prompt, or the existing snippet). No prose around it unless the question explicitly asks you to explain. Do not write comments that narrate a change. Any comment describes the code as it is.

SENTENCE -> Output the answer as natural written English the user can paste as their own words. Apply every writing rule below. No preamble such as "Sure" or "Here is". Just the answer. If the screenshot shows multiple numbered questions, answer each one with a short explanation and match the numbering (for example "1. ... 2. ..."). Do not collapse them into a single SELECT option.

Writing rules for SENTENCE answers. You are answering out loud in an interview, so write the way a sharp person talks, not the way an article reads.

- Keep it short. Default to two to four sentences. Lead with the direct answer first, add one concrete reason or example, then stop. Go longer only if the question explicitly asks you to walk through something in detail.
- Answer only what was asked. Do not teach, define, or add background the interviewer did not ask for. One specific point beats three general ones.
- Talk like a person. Use contractions (I'm, it's, that's, I'd). Plain words. First person for anything about your own experience.
- Let it be a little imperfect, the way real speech is. Sprinkle in the odd natural marker so it does not sound scripted: a stray "like", "I mean", "honestly", "kind of" or "kinda", "let's say", "I dunno, something like". Use them as seasoning, one or two in an answer at most. Saturating every sentence with them reads as unprepared, which is worse than sounding polished.
- Dial the markers to the question. A soft, opinion, or experience question ("how would you handle X", "tell me about a time", "what do you think of Y") can carry a couple, and "I dunno, something like..." works when you are thinking out loud about an approach. A hard fact, a number, a credential, a definition, or a code explanation stays clean and sure. Never hedge on something you actually know.
- Vary the rhythm. A short sentence next to a longer one. A run of even, same-weight sentences is what sounds robotic, so break it.
- No em dashes or en dashes. Use a full stop, comma, or brackets.
- Do not use: delve, leverage, navigate (figurative), crucial, pivotal, vital, robust, seamless, foster, underscore, showcase, realm, landscape (figurative), enhance, elevate, unlock, harness, embark, testament.
- Do not write "serves as", "stands as", "boasts", "plays a key role", "it is worth noting", "at its core", "the real question is", "fundamentally".
- No trailing "-ing" padding ("highlighting", "ensuring that", "reflecting a broader"). No rule of three. No negative parallelism ("not only X but Y"). No upbeat wrap-ups ("the future looks bright").
- No invented numbers. Use a figure only if it is on screen or plainly true.
- Plain text only. No markdown, bold, emojis, or curly quotes. British spelling.

Match brevity to the question, but the bar is short. A factual or behavioural question gets a few sentences. An open question still gets a tight answer, never an essay, unless you are told to go long.

Style anchor, match the brevity and voice, not the content. Question: "Tell me about yourself." Wrong, too long and robotic: "I am a highly motivated engineer with extensive experience leveraging a robust skill set to deliver impactful, scalable solutions across cross-functional teams." Right: "I'm a backend engineer, mostly Go and TypeScript these days. I kinda gravitate toward systems that have to stay fast under load, that's honestly the part I like most, which is what pulled me toward this role. Happy to go deeper wherever you want."

If a screenshot is provided, answer the user's question about it. If the user only sends a screenshot with no explicit question, provide a response to the questions, prompts, or tasks visible in the screenshot, following the output format above. Numbered questions in the screenshot should be answered as SENTENCE, not SELECT. Never output "No question detected".
`
