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
	body, token, err := c.requestCredentials(messages)
	if err != nil {
		return Answer{}, snap, err
	}
	answer, err := c.solveOnce(ctx, token, body, onDelta)
	if err == nil {
		return answer, snap, nil
	}
	if !isUnauthorized(err) {
		return Answer{}, snap, err
	}
	answer, err = c.reactivateAndRetry(ctx, body, onDelta)
	return answer, snap, err
}

func (c *proxyClient) requestCredentials(messages []Message) ([]byte, string, error) {
	body, err := c.buildBody(messages)
	if err != nil {
		return nil, "", err
	}
	token, err := c.token()
	if err != nil || token == "" {
		return nil, "", fmt.Errorf("Hermes Pass not activated")
	}
	return body, token, nil
}

func (c *proxyClient) reactivateAndRetry(ctx context.Context, body []byte, onDelta func(string)) (Answer, error) {
	act, err := c.reactivate(ctx)
	if err != nil {
		return Answer{}, fmt.Errorf("pass reactivation failed: %v", err)
	}
	if c.onBalance != nil {
		c.onBalance(act.BalancePct)
	}
	return c.solveOnce(ctx, act.Token, body, onDelta)
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
	if err := proxyResponseError(resp); err != nil {
		return Answer{}, err
	}
	var full strings.Builder
	if err := c.stream(resp.Body, &full, onDelta); err != nil {
		return Answer{}, err
	}
	return ParseAnswer(full.String()), nil
}

var proxyStatusErrors = map[int]error{
	http.StatusUnauthorized:    errUnauthorized{},
	http.StatusPaymentRequired: fmt.Errorf("Pass used up, top up to continue."),
	http.StatusForbidden:       fmt.Errorf("This pass has been revoked."),
}

func proxyResponseError(resp *http.Response) error {
	if resp.StatusCode == http.StatusOK {
		return nil
	}
	if err, ok := proxyStatusErrors[resp.StatusCode]; ok {
		return err
	}
	data, _ := io.ReadAll(resp.Body)
	return fmt.Errorf("proxy returned %d: %s", resp.StatusCode, string(data))
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
	if requestMode(messages) == DocumentMode {
		req["temperature"] = 0.2
		delete(req, "top_p")
		req["max_completion_tokens"] = 8192
		if supportsReasoningEffort(c.model) {
			req["reasoning_effort"] = "high"
		}
	}
	return json.Marshal(req)
}

func (c *proxyClient) stream(r io.Reader, full *strings.Builder, onDelta func(string)) error {
	scanner := bufio.NewScanner(r)
	for scanner.Scan() {
		chunk, done, ok := parseStreamLine(scanner.Text())
		if done {
			break
		}
		if ok {
			c.consumeStreamChunk(chunk, full, onDelta)
		}
	}
	return scanner.Err()
}

func (c *proxyClient) consumeStreamChunk(chunk streamChunk, full *strings.Builder, onDelta func(string)) {
	if chunk.Hermes != nil {
		c.reportBalance(chunk.Hermes.BalancePct)
		return
	}
	emitChoice(chunk, full, onDelta)
}

func (c *proxyClient) reportBalance(balance int) {
	if c.onBalance != nil {
		c.onBalance(balance)
	}
}

type errUnauthorized struct{}

func (errUnauthorized) Error() string { return "unauthorized" }

func isUnauthorized(err error) bool {
	_, ok := err.(errUnauthorized)
	return ok
}
