package speech

import (
	"testing"

	"github.com/stretchr/testify/assert"
)

func TestNew(t *testing.T) {
	tr := New("en-US")
	assert.NotNil(t, tr)
}

func TestAnalyzerAvailable(t *testing.T) {
	ok := AnalyzerAvailable()
	t.Logf("SpeechAnalyzer available: %v", ok)
}
