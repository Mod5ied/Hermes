package resume

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestExtractText(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "resume.txt")
	require.NoError(t, os.WriteFile(path, []byte("Go engineer with experience."), 0600))

	text, err := ExtractText(path)
	require.NoError(t, err)
	assert.Contains(t, text, "Go engineer")
}

func TestBuildProfileShort(t *testing.T) {
	in := "Short resume text."
	out, err := BuildProfile(in)
	require.NoError(t, err)
	assert.Equal(t, in, out)
}

func TestBuildProfileTruncate(t *testing.T) {
	in := strings.Repeat("word ", 500)
	out, err := BuildProfile(in)
	require.NoError(t, err)
	assert.True(t, len(strings.Fields(out)) <= 301)
}
