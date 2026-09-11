//go:build windows

package permissions

import (
	"fmt"
	"syscall"
	"unsafe"
)

// Kind identifies an operating-system capability used by Hermes.
type Kind int

const (
	ScreenRecording Kind = iota
	Accessibility
	SpeechRecognition
)

func (k Kind) Name() string {
	switch k {
	case ScreenRecording:
		return "Screen capture"
	case Accessibility:
		return "Input injection"
	case SpeechRecognition:
		return "On-device speech recognition"
	default:
		return "Unknown"
	}
}

type Check struct {
	Kind    Kind
	Granted bool
}

// Win32 desktop capture, SendInput, and local WASAPI loopback do not use the
// macOS-style TCC permission broker. Runtime API errors remain authoritative.
func CheckAll() []Check {
	return []Check{
		{Kind: ScreenRecording, Granted: true},
		{Kind: Accessibility, Granted: true},
		{Kind: SpeechRecognition, Granted: true},
	}
}

func Missing() []Check { return nil }

func EnsureAll() error { return nil }

var (
	user32Windows      = syscall.NewLazyDLL("user32.dll")
	messageBoxWWindows = user32Windows.NewProc("MessageBoxW")
)

func ShowAlert(message string) {
	text, err := syscall.UTF16PtrFromString(message)
	if err != nil {
		return
	}
	title, _ := syscall.UTF16PtrFromString("Hermes")
	messageBoxWWindows.Call(0, uintptr(unsafe.Pointer(text)), uintptr(unsafe.Pointer(title)), 0x00000010)
}

func permissionError(kind Kind, err error) error {
	return fmt.Errorf("%s unavailable: %w", kind.Name(), err)
}
