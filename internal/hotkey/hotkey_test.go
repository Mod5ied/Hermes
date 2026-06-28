package hotkey

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"golang.design/x/hotkey"
)

func TestParseCombo(t *testing.T) {
	mods, key, err := parseCombo("cmd+h")
	assert.NoError(t, err)
	assert.Equal(t, hotkey.KeyH, key)
	assert.Contains(t, mods, hotkey.ModCmd)
}

func TestParseComboEnter(t *testing.T) {
	mods, key, err := parseCombo("cmd+enter")
	assert.NoError(t, err)
	assert.Equal(t, hotkey.KeyReturn, key)
	_ = mods
}

func TestParseUnknown(t *testing.T) {
	_, _, err := parseCombo("cmd+unknown")
	assert.Error(t, err)
}
