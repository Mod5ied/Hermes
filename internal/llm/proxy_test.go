package llm

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/hermes/hermes/internal/config"
	"github.com/hermes/hermes/internal/pass"
	"github.com/stretchr/testify/assert"
)

func TestNewRoutesToProviderWhenAPIKeySet(t *testing.T) {
	cfg := config.Default()
	cfg.APIKey = "test-key"
	client := New(cfg, nil)
	_, ok := client.(*openAIClient)
	assert.True(t, ok, "BYOK key should route to direct provider client")
}

func TestNewRoutesToProxyWhenPassActive(t *testing.T) {
	cfg := config.Default()
	cfg.APIKey = ""
	cfg.PassActive = true
	client := New(cfg, nil)
	_, ok := client.(*proxyClient)
	assert.True(t, ok, "Pass active should route to proxy client")
}

func TestProxySolveReactivatesOn401AndRetriesOnce(t *testing.T) {
	calls := 0
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls++
		if r.URL.Path == "/activate" {
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write([]byte(`{"token":"fresh-token","expires_in":86400,"balance_micros":4000000,"balance_pct":100}`))
			return
		}
		auth := r.Header.Get("Authorization")
		if auth == "Bearer expired-token" {
			w.WriteHeader(http.StatusUnauthorized)
			_, _ = w.Write([]byte(`{"error":"invalid_token"}`))
			return
		}
		if auth == "Bearer fresh-token" {
			w.Header().Set("Content-Type", "text/event-stream")
			_, _ = w.Write([]byte("data: {\"choices\":[{\"delta\":{\"content\":\"hi\"}}]}\n\ndata: {\"hermes\":{\"balance_pct\":99}}\n\ndata: [DONE]\n\n"))
			return
		}
		w.WriteHeader(http.StatusForbidden)
	}))
	defer server.Close()

	c := NewProxy(config.Config{WorkerURL: server.URL, Model: "meta-llama/llama-4-scout-17b-16e-instruct"}, nil)
	c.(*proxyClient).tokenGetter = func() (string, error) { return "expired-token", nil }
	c.(*proxyClient).reactivator = func(ctx context.Context, workerURL string) (*pass.Activation, error) {
		resp, err := http.Post(workerURL+"/activate", "application/json", strings.NewReader(`{"pass_key":"test-key"}`))
		if err != nil {
			return nil, err
		}
		defer resp.Body.Close()
		if resp.StatusCode != http.StatusOK {
			return nil, fmt.Errorf("activation failed")
		}
		return &pass.Activation{Token: "fresh-token", BalancePct: 100}, nil
	}

	var got string
	ans, _, err := c.Solve(context.Background(), []Message{}, func(delta string) {
		got += delta
	})
	assert.NoError(t, err)
	assert.Equal(t, "hi", got)
	assert.Equal(t, Sentence, ans.Type)
	assert.Equal(t, 3, calls, "expected /v1/solve 401, /activate, /v1/solve success")
}

func TestProxySolveReturns402Exhausted(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusPaymentRequired)
		_, _ = w.Write([]byte(`{"error":"pass_exhausted","message":"Your Hermes Pass is used up. Top up to continue."}`))
	}))
	defer server.Close()

	c := NewProxy(config.Config{WorkerURL: server.URL, Model: "gemma-4-31b"}, nil)
	c.(*proxyClient).tokenGetter = func() (string, error) { return "token", nil }

	_, _, err := c.Solve(context.Background(), []Message{}, nil)
	assert.Error(t, err)
	assert.Contains(t, err.Error(), "Pass used up")
}

func TestProxySolveReturns403Revoked(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusForbidden)
		_, _ = w.Write([]byte(`{"error":"revoked","message":"This pass has been revoked."}`))
	}))
	defer server.Close()

	c := NewProxy(config.Config{WorkerURL: server.URL, Model: "gemma-4-31b"}, nil)
	c.(*proxyClient).tokenGetter = func() (string, error) { return "token", nil }

	_, _, err := c.Solve(context.Background(), []Message{}, nil)
	assert.Error(t, err)
	assert.Contains(t, err.Error(), "This pass has been revoked")
}
