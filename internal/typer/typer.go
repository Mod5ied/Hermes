// Package typer injects keystrokes using the native Peruzzi-style engine.
package typer

// #cgo LDFLAGS: -framework CoreFoundation -framework CoreGraphics
/*
#include <stdbool.h>
#include <stdlib.h>

void hermes_type_string(const char *utf8, unsigned long delayMicros, volatile int *stopFlag);
*/
import "C"
import (
	"math/rand"
	"sync"
	"time"
	"unsafe"
)

// Options configures the typer.
type Options struct {
	BaseDelay time.Duration
	Humanise  bool
}

// Typer injects keystrokes.
type Typer interface {
	Type(text string) error
	Stop()
}

// New creates a typer.
func New(opts Options) Typer {
	if opts.BaseDelay <= 0 {
		opts.BaseDelay = 25 * time.Millisecond
	}
	return &peruzziTyper{opts: opts}
}

type peruzziTyper struct {
	opts     Options
	stopFlag C.int
	mu       sync.Mutex
}

// Type types the given text. It blocks until finished or stopped.
func (t *peruzziTyper) Type(text string) error {
	if text == "" {
		return nil
	}
	t.mu.Lock()
	t.stopFlag = 0
	t.mu.Unlock()

	cstr := C.CString(text)
	defer C.free(unsafe.Pointer(cstr))

	delay := t.opts.BaseDelay
	if t.opts.Humanise {
		// Humanise adds jitter: vary base delay by +/- 30%.
		// The native function handles per-keystroke randomisation when delay is non-zero.
		delay = jitter(delay)
	}

	C.hermes_type_string(cstr, C.ulong(delay.Microseconds()), &t.stopFlag)
	return nil
}

// Stop halts an in-progress type.
func (t *peruzziTyper) Stop() {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.stopFlag = 1
}

func jitter(d time.Duration) time.Duration {
	f := d.Seconds()
	j := f * (0.7 + 0.6*rand.Float64())
	return time.Duration(j * float64(time.Second))
}
