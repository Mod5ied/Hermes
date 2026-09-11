//go:build windows

// Package typer injects Unicode keystrokes with the Win32 SendInput API.
package typer

import (
	"fmt"
	"math/rand"
	"sync/atomic"
	"syscall"
	"time"
	"unicode/utf16"
	"unsafe"
)

const (
	inputKeyboard    = 1
	keyeventfKeyup   = 0x0002
	keyeventfUnicode = 0x0004
	windowsInputSize = 40
)

var sendInputWindows = syscall.NewLazyDLL("user32.dll").NewProc("SendInput")

type Options struct {
	BaseDelay time.Duration
	Humanise  bool
}

type Typer interface {
	Type(text string) error
	Stop()
}

func New(opts Options) Typer {
	if opts.BaseDelay <= 0 {
		opts.BaseDelay = 25 * time.Millisecond
	}
	return &windowsTyper{opts: opts}
}

type keyboardInput struct {
	VirtualKey uint16
	ScanCode   uint16
	Flags      uint32
	Time       uint32
	Padding    uint32
	ExtraInfo  uintptr
}

type windowsInput struct {
	Type    uint32
	Padding uint32
	Key     keyboardInput
	Unused  [8]byte
}

type windowsTyper struct {
	opts Options
	stop atomic.Bool
}

func (t *windowsTyper) Type(text string) error {
	if text == "" {
		return nil
	}
	t.stop.Store(false)
	delay := t.opts.BaseDelay
	if t.opts.Humanise {
		delay = windowsJitter(delay)
	}

	for _, unit := range utf16.Encode([]rune(text)) {
		if t.stop.Load() {
			return nil
		}
		inputs := [2]windowsInput{
			{Type: inputKeyboard, Key: keyboardInput{ScanCode: unit, Flags: keyeventfUnicode}},
			{Type: inputKeyboard, Key: keyboardInput{ScanCode: unit, Flags: keyeventfUnicode | keyeventfKeyup}},
		}
		sent, _, callErr := sendInputWindows.Call(
			uintptr(len(inputs)),
			uintptr(unsafe.Pointer(&inputs[0])),
			uintptr(unsafe.Sizeof(inputs[0])),
		)
		if sent != uintptr(len(inputs)) {
			return fmt.Errorf("SendInput wrote %d of %d events: %w", sent, len(inputs), callErr)
		}
		if delay > 0 {
			time.Sleep(delay)
		}
	}
	return nil
}

func (t *windowsTyper) Stop() { t.stop.Store(true) }

func windowsJitter(delay time.Duration) time.Duration {
	factor := 0.7 + 0.6*rand.Float64()
	return time.Duration(float64(delay) * factor)
}

func init() {
	if unsafe.Sizeof(windowsInput{}) != windowsInputSize {
		panic("Hermes Windows SendInput ABI layout mismatch")
	}
}
