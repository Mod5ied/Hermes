//go:build darwin

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

type nativeTranscriber struct {
	locale string
	opMu   sync.Mutex
}

func newTranscriber(locale string) Transcriber {
	return &nativeTranscriber{locale: locale}
}

func analyzerAvailable() bool {
	return C.hermes_speech_analyzer_is_available() != 0
}

// Start begins capture and transcription.
func (t *nativeTranscriber) Start(onResult func(Result)) error {
	t.opMu.Lock()
	defer t.opMu.Unlock()
	if onResult == nil {
		return fmt.Errorf("no callback provided")
	}

	locale := t.locale
	if locale == "" {
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
	t.opMu.Lock()
	defer t.opMu.Unlock()
	C.hermes_speech_stop()
	callbacks.Range(func(key, value interface{}) bool {
		callbacks.Delete(key)
		return true
	})
	return nil
}

// Reset clears any accumulated transcript state.
func (t *nativeTranscriber) Reset() error {
	t.opMu.Lock()
	defer t.opMu.Unlock()
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
