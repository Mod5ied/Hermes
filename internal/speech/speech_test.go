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

func TestWhisperLanguage(t *testing.T) {
	tests := map[string]string{
		"":              "en",
		"en-US":         "en",
		"pt_BR":         "pt",
		" FR ":          "fr",
		"broken-locale": "en",
	}
	for locale, expected := range tests {
		assert.Equal(t, expected, whisperLanguage(locale), locale)
	}
}
