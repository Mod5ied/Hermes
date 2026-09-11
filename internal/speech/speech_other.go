//go:build !darwin && !windows

package speech

import "fmt"

type unsupportedTranscriber struct{}

func newTranscriber(string) Transcriber { return unsupportedTranscriber{} }
func analyzerAvailable() bool           { return false }

func (unsupportedTranscriber) Start(func(Result)) error {
	return fmt.Errorf("on-device speech transcription is not supported on this platform")
}
func (unsupportedTranscriber) Stop() error  { return nil }
func (unsupportedTranscriber) Reset() error { return nil }
