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
	assert.True(t, cfg.Stealth)
	assert.True(t, cfg.Humanise)
	assert.Equal(t, 25*time.Millisecond, cfg.BaseDelay)
	assert.Equal(t, 12, cfg.ContextTurns)
	assert.Equal(t, 1, cfg.ImageWindow)
}

func TestLoadSave(t *testing.T) {
	tmp := t.TempDir()
	orig := os.Getenv("HOME")
	os.Setenv("HOME", tmp)
	defer os.Setenv("HOME", orig)

	cfg := Default()
	cfg.APIKey = "test-key"
	cfg.Region = &Rect{X: 10, Y: 20, W: 100, H: 200}
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
