package config

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
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

// Rect represents a screen region in display pixels.
type Rect struct {
	X int `json:"x"`
	Y int `json:"y"`
	W int `json:"w"`
	H int `json:"h"`
}

// Config holds all user settings and runtime state.
type Config struct {
	APIKey        string        `json:"api_key"`
	BaseURL       string        `json:"base_url"`
	Model         string        `json:"model"`
	Provider      string        `json:"provider"`
	Stealth       bool          `json:"stealth"`
	Humanise      bool          `json:"humanise"`
	BaseDelay     time.Duration `json:"base_delay_ms"`
	Region        *Rect         `json:"region,omitempty"`
	ContextTurns  int           `json:"context_turns"`
	ImageWindow   int           `json:"image_window"`
	SpeechLocale  string        `json:"speech_locale"`
	ResumeProfile string        `json:"resume_profile"`
}

// Default returns a Config populated with defaults.
func Default() Config {
	return Config{
		BaseURL:      DefaultBase,
		Model:        "meta-llama/llama-4-scout-17b-16e-instruct",
		Provider:     ProviderGroq,
		Stealth:      true,
		Humanise:     true,
		BaseDelay:    90 * time.Millisecond,
		ContextTurns: 4,
		ImageWindow:  1,
		SpeechLocale: "",
	}
}

// ApplyProviderDefaults sets BaseURL and Model from the configured provider.
func ApplyProviderDefaults(c *Config) {
	switch c.Provider {
	case ProviderCerebras:
		c.BaseURL = "https://api.cerebras.ai/v1"
		if c.Model == "" || c.Model == "meta-llama/llama-4-scout-17b-16e-instruct" {
			c.Model = "llama3.1-70b"
		}
	default:
		c.Provider = ProviderGroq
		c.BaseURL = DefaultBase
		if c.Model == "" || c.Model == "llama3.1-70b" {
			c.Model = "meta-llama/llama-4-scout-17b-16e-instruct"
		}
	}
}

// Dir returns the application's support directory.
func Dir() (string, error) {
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

	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			if key := os.Getenv(APIKeyEnv); key != "" {
				cfg.APIKey = key
			}
			return cfg, nil
		}
		return cfg, fmt.Errorf("read config: %w", err)
	}

	if err := json.Unmarshal(data, &cfg); err != nil {
		return cfg, fmt.Errorf("parse config: %w", err)
	}

	if cfg.BaseURL == "" {
		cfg.BaseURL = DefaultBase
	}
	if cfg.Model == "" {
		cfg.Model = "meta-llama/llama-4-scout-17b-16e-instruct"
	}
	if cfg.Provider == "" {
		cfg.Provider = ProviderGroq
	}
	ApplyProviderDefaults(&cfg)
	if cfg.ContextTurns <= 0 {
		cfg.ContextTurns = 4
	}
	if cfg.ImageWindow < 0 || cfg.ImageWindow > 5 {
		cfg.ImageWindow = 1
	}

	if key := os.Getenv(APIKeyEnv); key != "" {
		cfg.APIKey = key
	}

	return cfg, nil
}

// Save writes the config file atomically with restrictive permissions.
func Save(c Config) error {
	path, err := Path()
	if err != nil {
		return err
	}

	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0700); err != nil {
		return fmt.Errorf("create config dir: %w", err)
	}

	data, err := json.MarshalIndent(c, "", "  ")
	if err != nil {
		return fmt.Errorf("marshal config: %w", err)
	}

	// Write to a temporary file and rename for atomicity.
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
	if c.APIKey == "" {
		return fmt.Errorf("Groq API key is not set. Add it in Settings or set %s", APIKeyEnv)
	}
	return nil
}
