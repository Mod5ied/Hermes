// Package speech provides on-device transcription of call-app audio.
package speech

// #cgo CFLAGS: -x objective-c
// #cgo LDFLAGS: -framework Cocoa -framework ScreenCaptureKit -framework Speech -framework AVFoundation -framework CoreMedia -L${SRCDIR} -lspeechswift
/*
#include <stdbool.h>
#include <stdlib.h>

int hermes_speech_start(const char *locale);
void hermes_speech_stop(void);
void hermes_speech_reset(void);
int hermes_speech_analyzer_is_available(void);
*/
import "C"
import (
	"fmt"
	"sync"
	"unsafe"
)

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
	return &nativeTranscriber{locale: locale}
}

// AnalyzerAvailable reports whether the macOS 26 SpeechAnalyzer path is
// available on this machine. It does not require any permissions.
func AnalyzerAvailable() bool {
	return C.hermes_speech_analyzer_is_available() != 0
}

type nativeTranscriber struct {
	locale string
}

// Start begins capture and transcription.
func (t *nativeTranscriber) Start(onResult func(Result)) error {
	if onResult == nil {
		return fmt.Errorf("no callback provided")
	}

	var locale string
	if t.locale != "" {
		locale = t.locale
	} else {
		locale = "en-US"
	}

	cLocale := C.CString(locale)
	defer C.free(unsafe.Pointer(cLocale))

	callbacks.Store(locale, onResult)
	ret := C.hermes_speech_start(cLocale)
	if ret != 0 {
		callbacks.Delete(locale)
		return fmt.Errorf("speech start failed (code %d)", int(ret))
	}
	return nil
}

// Stop ends capture and transcription.
func (t *nativeTranscriber) Stop() error {
	C.hermes_speech_stop()
	callbacks.Range(func(key, value interface{}) bool {
		callbacks.Delete(key)
		return true
	})
	return nil
}

// Reset clears any accumulated transcript state.
func (t *nativeTranscriber) Reset() error {
	C.hermes_speech_reset()
	return nil
}

var callbacks sync.Map // string locale -> func(Result)

//export hermesSpeechForward
func hermesSpeechForward(text *C.char, final C.int) {
	result := Result{Text: C.GoString(text), Final: final != 0}
	callbacks.Range(func(key, value interface{}) bool {
		if fn, ok := value.(func(Result)); ok {
			fn(result)
		}
		return true
	})
}
