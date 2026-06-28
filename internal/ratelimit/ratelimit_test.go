package ratelimit

import (
	"net/http"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
)

func TestParseSnapshot(t *testing.T) {
	h := http.Header{}
	h.Set("x-ratelimit-remaining-requests", "5")
	h.Set("x-ratelimit-remaining-tokens", "1000")
	h.Set("x-ratelimit-reset-requests", "2m30s")
	h.Set("x-ratelimit-reset-tokens", "7.66s")
	s := ParseSnapshot(h, 200)
	assert.Equal(t, 5, s.RemainingRequests)
	assert.Equal(t, 1000, s.RemainingTokens)
	assert.Equal(t, 150*time.Second, s.ResetRequests)
	assert.Equal(t, 7660*time.Millisecond, s.ResetTokens)
}

func TestParse429(t *testing.T) {
	h := http.Header{}
	h.Set("retry-after", "42")
	s := ParseSnapshot(h, 429)
	assert.Equal(t, 42*time.Second, s.RetryAfter)
}

func TestRPMWindow(t *testing.T) {
	tr := NewTracker("meta-llama/llama-4-scout-17b-16e-instruct")
	for i := 0; i < 30; i++ {
		tr.RecordSend()
	}
	ok, clearsIn, reason := tr.CanSend(1)
	assert.False(t, ok)
	assert.Equal(t, "requests per minute limit", reason)
	assert.True(t, clearsIn <= time.Minute)
}

func TestCooldown(t *testing.T) {
	tr := NewTracker("")
	tr.Update(Snapshot{RetryAfter: 10 * time.Second})
	ok, _, reason := tr.CanSend(1)
	assert.False(t, ok)
	assert.Equal(t, "rate limit cooldown", reason)
}
