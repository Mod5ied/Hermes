package documentcontext

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestAddPasteAndPromptBlock(t *testing.T) {
	s := New()
	require.NoError(t, s.AddPaste(`{"score": 4}`))
	summary := s.Summary()
	assert.Equal(t, 1, summary.Count)
	assert.Equal(t, []string{"Pasted context 1"}, summary.Names)
	assert.Contains(t, s.PromptBlock(), `<document index="1" name="Pasted context 1">`)
	assert.Contains(t, s.PromptBlock(), `{"score": 4}`)
}

func TestAddFileValidatesJSON(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "rubric.json")
	require.NoError(t, os.WriteFile(path, []byte(`{"valid":true}`), 0600))
	s := New()
	require.NoError(t, s.AddFile(path))
	assert.Equal(t, []string{"rubric.json"}, s.Summary().Names)

	require.NoError(t, os.WriteFile(path, []byte(`{"invalid"`), 0600))
	assert.ErrorContains(t, New().AddFile(path), "invalid JSON")
}

func TestLimitsAndClear(t *testing.T) {
	s := New()
	assert.Error(t, s.AddPaste(strings.Repeat("x", MaxFileBytes+1)))
	require.NoError(t, s.AddPaste("hello"))
	s.Clear()
	assert.Equal(t, 0, s.Summary().Count)
	assert.Empty(t, s.PromptBlock())
}
