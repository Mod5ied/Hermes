package permissions

// #cgo LDFLAGS: -framework Cocoa -framework ApplicationServices -framework Speech
/*
#include <stdbool.h>
#include <stdlib.h>

bool preflightScreenCapture(void);
bool preflightAccessibility(void);
int speechAuthorizationStatus(void);
void requestSpeechAuthorization(void);
void hermesShowAlert(const char *msg);
*/
import "C"
import (
	"fmt"
	"os"
	"unsafe"
)

// Kind identifies a TCC permission required by Hermes.
type Kind int

const (
	ScreenRecording Kind = iota
	Accessibility
	SpeechRecognition
)

// Name returns the user-facing macOS Settings label.
func (k Kind) Name() string {
	switch k {
	case ScreenRecording:
		return "Screen Recording"
	case Accessibility:
		return "Accessibility"
	case SpeechRecognition:
		return "Speech Recognition"
	default:
		return "Unknown"
	}
}

// Check holds the result for one permission.
type Check struct {
	Kind    Kind
	Granted bool
}

// CheckAll returns the status of all required permissions.
func CheckAll() []Check {
	return []Check{
		{Kind: ScreenRecording, Granted: bool(C.preflightScreenCapture())},
		{Kind: Accessibility, Granted: bool(C.preflightAccessibility())},
		{Kind: SpeechRecognition, Granted: int(C.speechAuthorizationStatus()) == 3}, // authorized
	}
}

// Missing returns only the permissions that are not granted.
func Missing() []Check {
	var missing []Check
	for _, c := range CheckAll() {
		if !c.Granted {
			missing = append(missing, c)
		}
	}
	return missing
}

// EnsureAll checks permissions. If any are missing it prints a warning but
// does NOT exit. The native APIs will trigger their own dialogs when the
// features are actually used. This avoids the app refusing to start just
// because the TCC preflight checks return stale results.
func EnsureAll() error {
	missing := Missing()
	if len(missing) == 0 {
		return nil
	}

	fmt.Fprintln(os.Stderr, "WARNING: Hermes is missing some macOS permissions:")
	names := make([]string, 0, len(missing))
	for _, c := range missing {
		fmt.Fprintf(os.Stderr, "  - %s\n", c.Kind.Name())
		names = append(names, c.Kind.Name())
	}
	fmt.Fprintln(os.Stderr, "The app will still start. Grant them in System Settings when prompted.")

	// Don't show a blocking alert here. The native APIs will prompt the user
	// when the features are actually used, and a modal alert would stall the
	// AppKit run loop before hotkeys can register.
	_ = names
	return nil
}

// ShowAlert displays a native alert with msg without blocking the caller.
func ShowAlert(msg string) {
	c := C.CString(msg)
	defer C.free(unsafe.Pointer(c))
	C.hermesShowAlert(c)
}
