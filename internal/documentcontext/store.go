// Package documentcontext stores user-supplied text context in memory.
package documentcontext

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"unicode/utf8"
)

const (
	MaxDocuments  = 12
	MaxFileBytes  = 256 * 1024
	MaxTotalBytes = 384 * 1024
)

// Document is one pasted or uploaded source supplied to the model.
type Document struct {
	Name    string
	Content string
}

// Summary is a safe UI snapshot of the current context.
type Summary struct {
	Count int
	Bytes int
	Names []string
}

// Store holds document context for the active document-task session.
type Store struct {
	mu        sync.Mutex
	documents []Document
	bytes     int
	pasteSeq  int
}

func New() *Store { return &Store{} }

// AddPaste adds text pasted into the context panel.
func (s *Store) AddPaste(content string) error {
	content = strings.TrimSpace(content)
	if content == "" {
		return fmt.Errorf("paste some text or JSON first")
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.pasteSeq++
	return s.addLocked(Document{
		Name:    fmt.Sprintf("Pasted context %d", s.pasteSeq),
		Content: content,
	})
}

// AddFile reads and adds one UTF-8 text or JSON file.
func (s *Store) AddFile(path string) error {
	name := filepath.Base(path)
	data, err := readDocumentFile(path, name)
	if err != nil {
		return err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.addLocked(Document{Name: name, Content: string(data)})
}

func readDocumentFile(path, name string) ([]byte, error) {
	info, err := os.Stat(path)
	if err != nil {
		return nil, fmt.Errorf("read %s: %w", name, err)
	}
	if err := validateFileInfo(info, name); err != nil {
		return nil, err
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read %s: %w", name, err)
	}
	return validateFileData(data, name)
}

func validateFileInfo(info os.FileInfo, name string) error {
	if !info.Mode().IsRegular() {
		return fmt.Errorf("%s is not a regular file", name)
	}
	if info.Size() > MaxFileBytes {
		return fmt.Errorf("%s exceeds the 256 KB per-file limit", name)
	}
	return nil
}

func validateFileData(data []byte, name string) ([]byte, error) {
	if !utf8.Valid(data) {
		return nil, fmt.Errorf("%s is not a UTF-8 text file", name)
	}
	if strings.EqualFold(filepath.Ext(name), ".json") && !json.Valid(data) {
		return nil, fmt.Errorf("%s contains invalid JSON", name)
	}
	return data, nil
}

func (s *Store) addLocked(doc Document) error {
	if len(s.documents) >= MaxDocuments {
		return fmt.Errorf("document limit is %d", MaxDocuments)
	}
	size := len(doc.Content)
	if size > MaxFileBytes {
		return fmt.Errorf("context item exceeds the 256 KB limit")
	}
	if s.bytes+size > MaxTotalBytes {
		return fmt.Errorf("document context exceeds the 384 KB total limit")
	}
	s.documents = append(s.documents, doc)
	s.bytes += size
	return nil
}

func (s *Store) Clear() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.documents = nil
	s.bytes = 0
	s.pasteSeq = 0
}

func (s *Store) Summary() Summary {
	s.mu.Lock()
	defer s.mu.Unlock()
	names := make([]string, len(s.documents))
	for i, doc := range s.documents {
		names[i] = doc.Name
	}
	return Summary{Count: len(s.documents), Bytes: s.bytes, Names: names}
}

// PromptBlock returns untrusted source material with explicit boundaries.
func (s *Store) PromptBlock() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	var b strings.Builder
	for i, doc := range s.documents {
		fmt.Fprintf(&b, "<document index=\"%d\" name=\"%s\">\n", i+1, escapeAttribute(doc.Name))
		b.WriteString(doc.Content)
		if !strings.HasSuffix(doc.Content, "\n") {
			b.WriteByte('\n')
		}
		b.WriteString("</document>\n")
	}
	return b.String()
}

func escapeAttribute(value string) string {
	return strings.NewReplacer(
		"&", "&amp;",
		"\"", "&quot;",
		"'", "&#39;",
		"<", "&lt;",
		">", "&gt;",
	).Replace(value)
}
