package pass

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/hermes/hermes/internal/config"
	"github.com/hermes/hermes/internal/keychain"
)

const (
	serviceName   = "Hermes"
	passKeyAccount = "hermes-pass-key"
	tokenAccount   = "hermes-pass-token"
)

// Activation is the response from the Worker /activate endpoint.
type Activation struct {
	Token         string `json:"token"`
	ExpiresIn     int    `json:"expires_in"`
	BalanceMicros int64  `json:"balance_micros"`
	BalancePct    int    `json:"balance_pct"`
}

// ResolveWorkerURL returns the configured Worker origin.
func ResolveWorkerURL(cfg config.Config) string {
	if cfg.WorkerURL != "" {
		return strings.TrimRight(cfg.WorkerURL, "/")
	}
	if u := os.Getenv("HERMES_WORKER_URL"); u != "" {
		return strings.TrimRight(u, "/")
	}
	return ""
}

// Activate exchanges a pass key for a short-lived token and stores both in the Keychain.
func Activate(ctx context.Context, workerURL, passKey string) (*Activation, error) {
	act, err := callActivate(ctx, workerURL, passKey)
	if err != nil {
		return nil, err
	}
	if err := keychain.SetPassword(serviceName, passKeyAccount, passKey); err != nil {
		return nil, fmt.Errorf("store pass key: %w", err)
	}
	if err := keychain.SetPassword(serviceName, tokenAccount, act.Token); err != nil {
		return nil, fmt.Errorf("store token: %w", err)
	}
	return act, nil
}

// Reactivate fetches a fresh token using the pass key already in the Keychain.
func Reactivate(ctx context.Context, workerURL string) (*Activation, error) {
	pk, err := PassKey()
	if err != nil {
		return nil, fmt.Errorf("no stored pass key: %w", err)
	}
	return Activate(ctx, workerURL, pk)
}

// Active reports whether a token is stored in the Keychain.
func Active() bool {
	tok, err := Token()
	return err == nil && tok != ""
}

// Token returns the stored Hermes token.
func Token() (string, error) {
	return keychain.GetPassword(serviceName, tokenAccount)
}

// PassKey returns the stored Hermes pass key.
func PassKey() (string, error) {
	return keychain.GetPassword(serviceName, passKeyAccount)
}

// SetToken stores a token directly (used after reactivation in the client).
func SetToken(token string) error {
	return keychain.SetPassword(serviceName, tokenAccount, token)
}

// Clear removes stored pass credentials.
func Clear() error {
	_ = keychain.DeletePassword(serviceName, tokenAccount)
	_ = keychain.DeletePassword(serviceName, passKeyAccount)
	return nil
}

func callActivate(ctx context.Context, workerURL, passKey string) (*Activation, error) {
	u := strings.TrimRight(workerURL, "/") + "/activate"
	body, _ := json.Marshal(map[string]string{"pass_key": passKey})
	req, err := http.NewRequestWithContext(ctx, "POST", u, bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")

	client := &http.Client{Timeout: 30 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		msg := readMessage(resp.Body)
		if msg == "" {
			msg = fmt.Sprintf("activation failed with status %d", resp.StatusCode)
		}
		return nil, fmt.Errorf("%s", msg)
	}

	var act Activation
	if err := json.NewDecoder(resp.Body).Decode(&act); err != nil {
		return nil, fmt.Errorf("decode activation: %w", err)
	}
	return &act, nil
}

func readMessage(r io.Reader) string {
	data, _ := io.ReadAll(r)
	if len(data) == 0 {
		return ""
	}
	var m struct {
		Message string `json:"message"`
		Error   string `json:"error"`
	}
	if json.Unmarshal(data, &m) == nil && m.Message != "" {
		return m.Message
	}
	if json.Unmarshal(data, &m) == nil && m.Error != "" {
		return m.Error
	}
	return string(bytes.TrimSpace(data))
}
