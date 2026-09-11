// Package speech provides on-device transcription of call-app audio.
package speech

// Result is emitted as transcription progresses.
type Result struct {
	Text  string
	Final bool
}

// Transcriber captures call-app audio and transcribes it on-device.
type Transcriber interface {
	Start(onResult func(Result)) error
	Stop() error
	Reset() error
}

// New creates a transcriber for the given locale (empty uses system locale).
func New(locale string) Transcriber {
	return newTranscriber(locale)
}

// AnalyzerAvailable reports whether the platform-native analyzer path is
// available. Windows uses the bundled whisper.cpp engine and returns false.
func AnalyzerAvailable() bool {
	return analyzerAvailable()
}
