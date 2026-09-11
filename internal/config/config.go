package config

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"time"
)

const (
	AppDirName  = "Hermes"
	ConfigName  = "config.json"
	APIKeyEnv   = "HERMES_GROQ_API_KEY"
	DefaultBase = "https://api.groq.com/openai/v1"

	ProviderGroq     = "Groq"
	ProviderCerebras = "Cerebras"
)

// ModelInfo describes one model available for a provider.
type ModelInfo struct {
	Name   string `json:"name"`
	Vision bool   `json:"vision"`
}

// ProviderModels maps each provider to its available models.
var ProviderModels = map[string][]ModelInfo{
	ProviderGroq: {
		{Name: "meta-llama/llama-4-scout-17b-16e-instruct", Vision: true},
	},
	ProviderCerebras: {
		{Name: "gpt-oss-120b", Vision: false},
		{Name: "qwen-3.8-27b", Vision: true},
	},
}

var deprecatedCerebrasModels = map[string]string{
	"gemma-4-31b": "qwen-3.8-27b",
	"zai-glm-4.7": "gpt-oss-120b",
}

// ProviderBaseURLs maps each provider to its API endpoint.
var ProviderBaseURLs = map[string]string{
	ProviderGroq:     DefaultBase,
	ProviderCerebras: "https://api.cerebras.ai/v1",
}

// DefaultModel returns the default model for a provider.
func DefaultModel(provider string) string {
	models := ProviderModels[provider]
	if len(models) > 0 {
		return models[0].Name
	}
	return ProviderModels[ProviderGroq][0].Name
}

// IsVisionModel reports whether the given model supports image inputs.
func IsVisionModel(provider, model string) bool {
	for _, m := range ProviderModels[provider] {
		if m.Name == model {
			return m.Vision
		}
	}
	return false
}

// Rect represents a screen region in display pixels.
type Rect struct {
	X int `json:"x"`
	Y int `json:"y"`
	W int `json:"w"`
	H int `json:"h"`
}

// Config holds all user settings and runtime state.
type Config struct {
	APIKey         string            `json:"api_key"`
	APIKeys        map[string]string `json:"provider_api_keys,omitempty"`
	BaseURL        string            `json:"base_url"`
	Model          string            `json:"model"`
	Provider       string            `json:"provider"`
	Stealth        bool              `json:"stealth"`
	Humanise       bool              `json:"humanise"`
	BaseDelay      time.Duration     `json:"base_delay_ms"`
	Region         *Rect             `json:"region,omitempty"`
	ContextTurns   int               `json:"context_turns"`
	ImageWindow    int               `json:"image_window"`
	SpeechLocale   string            `json:"speech_locale"`
	ResumeProfile  string            `json:"resume_profile"`
	WorkerURL      string            `json:"worker_url,omitempty"`
	PassActive     bool              `json:"pass_active,omitempty"`
	OverlayOpacity int               `json:"overlay_opacity"`
	AnswerFontSize int               `json:"answer_font_size"`
}

// Default returns a Config populated with defaults.
func Default() Config {
	return Config{
		BaseURL:        DefaultBase,
		Model:          ProviderModels[ProviderGroq][0].Name,
		Provider:       ProviderGroq,
		Stealth:        true,
		Humanise:       true,
		BaseDelay:      90 * time.Millisecond,
		ContextTurns:   4,
		ImageWindow:    1,
		SpeechLocale:   "",
		WorkerURL:      "https://hermes-proxy.ogwurup.workers.dev",
		OverlayOpacity: 85,
		AnswerFontSize: 11,
	}
}

// ApplyProviderDefaults sets BaseURL and Model from the configured provider and
// keeps the active API key in sync with the per-provider key store.
func ApplyProviderDefaults(c *Config) {
	c.Provider = supportedProvider(c.Provider)
	c.BaseURL = ProviderBaseURLs[c.Provider]
	if c.Provider == ProviderCerebras {
		if replacement, ok := deprecatedCerebrasModels[c.Model]; ok {
			c.Model = replacement
		}
	}
	if !modelExists(c.Provider, c.Model) {
		c.Model = DefaultModel(c.Provider)
	}
	ensureAPIKeys(c)
	if key, ok := c.APIKeys[c.Provider]; ok && key != "" {
		c.APIKey = key
	}
}

func supportedProvider(provider string) string {
	if _, ok := ProviderBaseURLs[provider]; ok {
		return provider
	}
	return ProviderGroq
}

func ensureAPIKeys(c *Config) {
	if c.APIKeys == nil {
		c.APIKeys = map[string]string{}
	}
}

func modelExists(provider, model string) bool {
	for _, m := range ProviderModels[provider] {
		if m.Name == model {
			return true
		}
	}
	return false
}

// Dir returns the application's support directory.
func Dir() (string, error) {
	if runtime.GOOS == "windows" {
		root, err := os.UserConfigDir()
		if err != nil {
			return "", fmt.Errorf("user config dir: %w", err)
		}
		return filepath.Join(root, AppDirName), nil
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return "", fmt.Errorf("user home dir: %w", err)
	}
	dir := filepath.Join(home, "Library", "Application Support", AppDirName)
	return dir, nil
}

// Path returns the full path to the config file.
func Path() (string, error) {
	dir, err := Dir()
	if err != nil {
		return "", err
	}
	return filepath.Join(dir, ConfigName), nil
}

// Load reads the config file, creating defaults if missing. The Groq API key
// may be overridden by the HERMES_GROQ_API_KEY environment variable.
func Load() (Config, error) {
	cfg := Default()
	path, err := Path()
	if err != nil {
		return cfg, err
	}
	data, missing, err := readConfig(path)
	if err != nil {
		return cfg, err
	}
	if missing {
		applyEnvironmentKey(&cfg)
		return cfg, nil
	}
	if err := json.Unmarshal(data, &cfg); err != nil {
		return cfg, fmt.Errorf("parse config: %w", err)
	}
	normalizeLoaded(&cfg)
	applyEnvironmentKey(&cfg)
	return cfg, nil
}

func readConfig(path string) ([]byte, bool, error) {
	data, err := os.ReadFile(path)
	if os.IsNotExist(err) {
		return nil, true, nil
	}
	if err != nil {
		return nil, false, fmt.Errorf("read config: %w", err)
	}
	return data, false, nil
}

func normalizeLoaded(cfg *Config) {
	applyLegacyDefaults(cfg)
	migrateAPIKey(cfg)
	ApplyProviderDefaults(cfg)
	clampContextSettings(cfg)
	clampDisplaySettings(cfg)
}

func applyLegacyDefaults(cfg *Config) {
	if cfg.BaseURL == "" {
		cfg.BaseURL = DefaultBase
	}
	if cfg.Model == "" {
		cfg.Model = DefaultModel(ProviderGroq)
	}
	if cfg.Provider == "" {
		cfg.Provider = ProviderGroq
	}
}

func migrateAPIKey(cfg *Config) {
	ensureAPIKeys(cfg)
	if _, exists := cfg.APIKeys[cfg.Provider]; cfg.APIKey != "" && !exists {
		cfg.APIKeys[cfg.Provider] = cfg.APIKey
	}
}

func clampContextSettings(cfg *Config) {
	if cfg.ContextTurns <= 0 {
		cfg.ContextTurns = 4
	}
	if cfg.ImageWindow < 0 || cfg.ImageWindow > 5 {
		cfg.ImageWindow = 1
	}
}

func clampDisplaySettings(cfg *Config) {
	if cfg.OverlayOpacity < 20 {
		cfg.OverlayOpacity = 20
	}
	if cfg.OverlayOpacity > 100 {
		cfg.OverlayOpacity = 100
	}
	if cfg.AnswerFontSize < 9 {
		cfg.AnswerFontSize = 9
	}
	if cfg.AnswerFontSize > 16 {
		cfg.AnswerFontSize = 16
	}
}

func applyEnvironmentKey(cfg *Config) {
	if key := os.Getenv(APIKeyEnv); key != "" {
		cfg.APIKey = key
	}
}

// Save writes the config file atomically with restrictive permissions.
func Save(c Config) error {
	path, err := Path()
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return fmt.Errorf("create config dir: %w", err)
	}
	data, err := json.MarshalIndent(c, "", "  ")
	if err != nil {
		return fmt.Errorf("marshal config: %w", err)
	}
	return writeAtomic(path, data)
}

func writeAtomic(path string, data []byte) error {
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, 0600); err != nil {
		return fmt.Errorf("write config temp: %w", err)
	}
	if err := os.Rename(tmp, path); err != nil {
		os.Remove(tmp)
		return fmt.Errorf("rename config: %w", err)
	}
	return nil
}

// ValidateSend returns an error if the app is not allowed to send a request.
func (c Config) ValidateSend() error {
	if c.PassActive {
		return nil
	}
	if c.APIKey == "" {
		return fmt.Errorf("%s API key is not set. Add it in Settings, set a Hermes Pass, or set %s", c.Provider, APIKeyEnv)
	}
	return nil
}
