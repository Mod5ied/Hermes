package config

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestDefault(t *testing.T) {
	cfg := Default()
	assert.Equal(t, "meta-llama/llama-4-scout-17b-16e-instruct", cfg.Model)
	assert.Equal(t, ProviderGroq, cfg.Provider)
	assert.True(t, cfg.Stealth)
	assert.True(t, cfg.Humanise)
	assert.Equal(t, 90*time.Millisecond, cfg.BaseDelay)
	assert.Equal(t, 4, cfg.ContextTurns)
	assert.Equal(t, 1, cfg.ImageWindow)
}

func TestCerebrasModelsContainOnlySupportedOptions(t *testing.T) {
	assert.Equal(t, []ModelInfo{
		{Name: "gpt-oss-120b", Vision: false},
		{Name: "qwen-3.8-27b", Vision: true},
	}, ProviderModels[ProviderCerebras])
}

func TestApplyProviderDefaultsMigratesDeprecatedCerebrasModels(t *testing.T) {
	tests := map[string]string{
		"gemma-4-31b": "qwen-3.8-27b",
		"zai-glm-4.7": "gpt-oss-120b",
	}
	for old, want := range tests {
		cfg := Config{Provider: ProviderCerebras, Model: old}
		ApplyProviderDefaults(&cfg)
		assert.Equal(t, want, cfg.Model)
	}
}

func TestLoadSave(t *testing.T) {
	tmp := t.TempDir()
	orig := os.Getenv("HOME")
	os.Setenv("HOME", tmp)
	defer os.Setenv("HOME", orig)

	cfg := Default()
	cfg.APIKey = "test-key"
	cfg.Region = &Rect{X: 10, Y: 20, W: 100, H: 200}
	ApplyProviderDefaults(&cfg)
	require.NoError(t, Save(cfg))

	loaded, err := Load()
	require.NoError(t, err)
	assert.Equal(t, cfg.APIKey, loaded.APIKey)
	assert.Equal(t, cfg.Region, loaded.Region)
}

func TestEnvOverride(t *testing.T) {
	tmp := t.TempDir()
	origHome := os.Getenv("HOME")
	os.Setenv("HOME", tmp)
	defer os.Setenv("HOME", origHome)

	origKey := os.Getenv(APIKeyEnv)
	os.Setenv(APIKeyEnv, "env-key")
	defer os.Setenv(APIKeyEnv, origKey)

	cfg := Default()
	cfg.APIKey = "file-key"
	require.NoError(t, Save(cfg))

	loaded, err := Load()
	require.NoError(t, err)
	assert.Equal(t, "env-key", loaded.APIKey)
}

func TestValidateSend(t *testing.T) {
	cfg := Default()
	assert.Error(t, cfg.ValidateSend())
	cfg.APIKey = "key"
	assert.NoError(t, cfg.ValidateSend())
}

func TestPermissions(t *testing.T) {
	path, err := Path()
	require.NoError(t, err)
	assert.True(t, filepath.IsAbs(path))
}
