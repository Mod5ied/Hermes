package llm

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"

	"github.com/hermes/hermes/internal/config"
	"github.com/hermes/hermes/internal/pass"
	"github.com/hermes/hermes/internal/ratelimit"
)

// NewProxy creates a client that routes through the Hermes Worker.
func NewProxy(cfg config.Config, onBalance func(int)) Client {
	return &proxyClient{
		workerURL: pass.ResolveWorkerURL(cfg),
		model:     cfg.Model,
		onBalance: onBalance,
	}
}

type proxyClient struct {
	workerURL   string
	model       string
	onBalance   func(int)
	tokenGetter func() (string, error)
	reactivator func(ctx context.Context, workerURL string) (*pass.Activation, error)
}

func (c *proxyClient) token() (string, error) {
	if c.tokenGetter != nil {
		return c.tokenGetter()
	}
	return pass.Token()
}

func (c *proxyClient) reactivate(ctx context.Context) (*pass.Activation, error) {
	if c.reactivator != nil {
		return c.reactivator(ctx, c.workerURL)
	}
	return pass.Reactivate(ctx, c.workerURL)
}

func (c *proxyClient) Solve(ctx context.Context, messages []Message, onDelta func(text string)) (Answer, ratelimit.Snapshot, error) {
	var snap ratelimit.Snapshot
	body, err := c.buildBody(messages)
	if err != nil {
		return Answer{}, snap, err
	}

	token, err := c.token()
	if err != nil || token == "" {
		return Answer{}, snap, fmt.Errorf("Hermes Pass not activated")
	}

	answer, err := c.solveOnce(ctx, token, body, onDelta)
	if err == nil {
		return answer, snap, nil
	}

	// 401 => silently re-activate once and retry.
	if isUnauthorized(err) {
		act, rerr := c.reactivate(ctx)
		if rerr != nil {
			return Answer{}, snap, fmt.Errorf("pass reactivation failed: %v", rerr)
		}
		if c.onBalance != nil {
			c.onBalance(act.BalancePct)
		}
		answer, err = c.solveOnce(ctx, act.Token, body, onDelta)
	}

	if err != nil {
		return Answer{}, snap, err
	}
	return answer, snap, nil
}

func (c *proxyClient) solveOnce(ctx context.Context, token string, body []byte, onDelta func(text string)) (Answer, error) {
	req, err := http.NewRequestWithContext(ctx, "POST", c.workerURL+"/v1/solve", bytes.NewReader(body))
	if err != nil {
		return Answer{}, err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+token)

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return Answer{}, err
	}
	defer resp.Body.Close()

	if resp.StatusCode == http.StatusUnauthorized {
		return Answer{}, errUnauthorized{}
	}
	if resp.StatusCode == http.StatusPaymentRequired {
		return Answer{}, fmt.Errorf("Pass used up, top up to continue.")
	}
	if resp.StatusCode == http.StatusForbidden {
		return Answer{}, fmt.Errorf("This pass has been revoked.")
	}
	if resp.StatusCode != http.StatusOK {
		data, _ := io.ReadAll(resp.Body)
		return Answer{}, fmt.Errorf("proxy returned %d: %s", resp.StatusCode, string(data))
	}

	var full strings.Builder
	if err := c.stream(resp.Body, &full, onDelta); err != nil {
		return Answer{}, err
	}
	return ParseAnswer(full.String()), nil
}

func (c *proxyClient) buildBody(messages []Message) ([]byte, error) {
	req := map[string]interface{}{
		"model":                 c.model,
		"stream":                true,
		"temperature":           0.3,
		"top_p":                 0.95,
		"max_completion_tokens": 768,
		"messages":              buildAPIMessages(messages),
	}
	return json.Marshal(req)
}

func (c *proxyClient) stream(r io.Reader, full *strings.Builder, onDelta func(string)) error {
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
			Hermes *struct {
				BalancePct int `json:"balance_pct"`
			} `json:"hermes"`
			Choices []struct {
				Delta struct {
					Content string `json:"content"`
				} `json:"delta"`
			} `json:"choices"`
		}
		if err := json.Unmarshal([]byte(data), &chunk); err != nil {
			continue
		}
		if chunk.Hermes != nil && c.onBalance != nil {
			c.onBalance(chunk.Hermes.BalancePct)
			continue
		}
		if len(chunk.Choices) > 0 {
			delta := chunk.Choices[0].Delta.Content
			full.WriteString(delta)
			if onDelta != nil {
				onDelta(delta)
			}
		}
	}
	return scanner.Err()
}

type errUnauthorized struct{}

func (errUnauthorized) Error() string { return "unauthorized" }

func isUnauthorized(err error) bool {
	_, ok := err.(errUnauthorized)
	return ok
}
