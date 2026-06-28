// Package ratelimit tracks Groq rate limits from response headers and local RPM state.
package ratelimit

import (
	"fmt"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"
)

// Snapshot is parsed from Groq response headers.
type Snapshot struct {
	RemainingRequests int
	RemainingTokens   int
	ResetRequests     time.Duration
	ResetTokens       time.Duration
	RetryAfter        time.Duration
}

// ParseSnapshot extracts rate-limit fields from HTTP headers.
func ParseSnapshot(h http.Header, statusCode int) Snapshot {
	s := Snapshot{}
	if statusCode == http.StatusTooManyRequests {
		s.RetryAfter = parseSeconds(h.Get("retry-after"))
	}
	s.RemainingRequests = parseInt(h.Get("x-ratelimit-remaining-requests"))
	s.RemainingTokens = parseInt(h.Get("x-ratelimit-remaining-tokens"))
	s.ResetRequests = parseDuration(h.Get("x-ratelimit-reset-requests"))
	s.ResetTokens = parseDuration(h.Get("x-ratelimit-reset-tokens"))
	return s
}

func parseInt(v string) int {
	if v == "" {
		return -1
	}
	n, err := strconv.Atoi(v)
	if err != nil {
		return -1
	}
	return n
}

func parseSeconds(v string) time.Duration {
	n, err := strconv.Atoi(v)
	if err != nil {
		return 0
	}
	return time.Duration(n) * time.Second
}

func parseDuration(v string) time.Duration {
	if v == "" {
		return 0
	}
	// Groq returns values like "2m59.56s" which time.ParseDuration handles.
	d, err := time.ParseDuration(strings.TrimSpace(v))
	if err != nil {
		return 0
	}
	return d
}

// DefaultLimits for Llama 4 Scout free tier.
type DefaultLimits struct {
	RPM int
	RPD int
	TPM int
	TPD int
}

// LimitsForModel returns seeded limits. Unknown models use conservative defaults.
func LimitsForModel(model string) DefaultLimits {
	if strings.Contains(model, "llama-4-scout") {
		return DefaultLimits{RPM: 30, RPD: 1000, TPM: 30000, TPD: 500000}
	}
	return DefaultLimits{RPM: 30, RPD: 1000, TPM: 30000, TPD: 500000}
}

// Tracker evaluates whether a send is allowed.
type Tracker struct {
	mu              sync.Mutex
	limits          DefaultLimits
	sendTimes       []time.Time
	lastSnapshot    Snapshot
	snapshotUpdated time.Time
	cooldownUntil   time.Time
}

// NewTracker creates a tracker seeded for the given model.
func NewTracker(model string) *Tracker {
	return &Tracker{
		limits:    LimitsForModel(model),
		sendTimes: make([]time.Time, 0, 64),
	}
}

// RecordSend stamps a new send for the RPM window.
func (t *Tracker) RecordSend() {
	t.mu.Lock()
	defer t.mu.Unlock()
	now := time.Now()
	t.sendTimes = append(t.sendTimes, now)
	t.trim(now)
}

// Update folds response headers into the tracker.
func (t *Tracker) Update(s Snapshot) {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.lastSnapshot = s
	t.snapshotUpdated = time.Now()
	if s.RetryAfter > 0 {
		t.cooldownUntil = time.Now().Add(s.RetryAfter)
	}
}

// CanSend reports whether a send is currently allowed and when it will clear.
func (t *Tracker) CanSend(estTokens int) (bool, time.Duration, string) {
	t.mu.Lock()
	defer t.mu.Unlock()

	now := time.Now()
	t.trim(now)

	// Cooldown from a 429 takes priority.
	if now.Before(t.cooldownUntil) {
		return false, t.cooldownUntil.Sub(now), "rate limit cooldown"
	}

	// RPM window.
	if len(t.sendTimes) >= t.limits.RPM {
		oldest := t.sendTimes[0]
		clearsIn := oldest.Add(time.Minute).Sub(now)
		if clearsIn > 0 {
			return false, clearsIn, "requests per minute limit"
		}
	}

	// RPD header-based.
	if t.lastSnapshot.RemainingRequests == 0 && t.lastSnapshot.ResetRequests > 0 {
		expires := t.snapshotUpdated.Add(t.lastSnapshot.ResetRequests)
		if now.Before(expires) {
			return false, expires.Sub(now), "requests per day limit"
		}
	}

	// TPM header-based.
	if t.lastSnapshot.RemainingTokens >= 0 && estTokens > t.lastSnapshot.RemainingTokens {
		if t.lastSnapshot.ResetTokens > 0 {
			expires := t.snapshotUpdated.Add(t.lastSnapshot.ResetTokens)
			if now.Before(expires) {
				return false, expires.Sub(now), "tokens per minute limit"
			}
		}
	}

	return true, 0, ""
}

func (t *Tracker) trim(now time.Time) {
	cutoff := now.Add(-time.Minute)
	keep := 0
	for _, ts := range t.sendTimes {
		if ts.After(cutoff) {
			t.sendTimes[keep] = ts
			keep++
		}
	}
	t.sendTimes = t.sendTimes[:keep]
}

// EstimateTokens gives a rough token count for a send.
func EstimateTokens(systemPrompt, instruction string, images int) int {
	// 1 token ~= 4 chars for English text; add a constant per screenshot.
	text := len(systemPrompt) + len(instruction)
	return text/4 + images*800 + 100
}

// FormatDuration rounds a duration to the nearest second for display.
func FormatDuration(d time.Duration) string {
	if d < time.Second {
		return "<1s"
	}
	return fmt.Sprintf("%ds", int(d.Round(time.Second).Seconds()))
}
