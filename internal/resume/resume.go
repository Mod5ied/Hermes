// Package resume extracts resume text and builds a compact candidate profile.
package resume

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/ledongthuc/pdf"
)

// ExtractText reads plain text from a .txt or .pdf file.
func ExtractText(path string) (string, error) {
	ext := strings.ToLower(filepath.Ext(path))
	switch ext {
	case ".txt":
		data, err := os.ReadFile(path)
		if err != nil {
			return "", fmt.Errorf("read text file: %w", err)
		}
		return string(data), nil
	case ".pdf":
		return extractPDF(path)
	default:
		return "", fmt.Errorf("unsupported resume format: %s", ext)
	}
}

func extractPDF(path string) (string, error) {
	f, r, err := pdf.Open(path)
	if err != nil {
		return "", fmt.Errorf("open pdf: %w", err)
	}
	defer f.Close()

	var b strings.Builder
	var buf strings.Builder
	totalPage := r.NumPage()
	for pageIndex := 1; pageIndex <= totalPage; pageIndex++ {
		p := r.Page(pageIndex)
		if p.V.IsNull() {
			continue
		}
		buf.Reset()
		texts := p.Content().Text
		for _, text := range texts {
			buf.WriteString(text.S)
		}
		if buf.Len() > 0 {
			b.WriteString(buf.String())
			b.WriteString("\n")
		}
	}
	return b.String(), nil
}

// BuildProfile compacts raw resume text to roughly 200-300 words.
// If the text is already short it is returned cleaned up.
func BuildProfile(text string) (string, error) {
	text = cleanText(text)
	words := strings.Fields(text)
	if len(words) <= 300 {
		return text, nil
	}

	// Simple truncation keeping the first 300 words. A later upgrade could use
	// a one-time Groq summarisation call.
	truncated := strings.Join(words[:300], " ")
	return truncated + "...", nil
}

func cleanText(text string) string {
	lines := strings.Split(text, "\n")
	var out []string
	for _, line := range lines {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		out = append(out, line)
	}
	return strings.Join(out, "\n")
}
