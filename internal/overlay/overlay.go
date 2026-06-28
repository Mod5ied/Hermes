// Package overlay drives the native NSPanel command bar.
package overlay

// #cgo CFLAGS: -x objective-c
// #cgo LDFLAGS: -framework Cocoa -framework CoreGraphics
/*
#include <stdbool.h>
#include <stdlib.h>

void hermesOverlayInit(bool stealth);
void hermesOverlayShow(void);
void hermesOverlayHide(void);
void hermesOverlaySetStealth(bool on);
void hermesOverlaySetInstruction(const char *text);
char *hermesOverlayGetInstruction(void);
void hermesOverlayAppendInstruction(const char *text, bool final);
void hermesOverlayBeginAnswer(void);
void hermesOverlayAppendAnswer(const char *delta);
void hermesOverlayFinalizeAnswer(const char *text);
void hermesOverlaySetIndicator(bool canSend, int clearsInSeconds);
void hermesOverlaySetBusy(bool on);
void hermesOverlaySetTrayCount(int n);
void hermesOverlaySetAnswerCount(int n);
void hermesOverlayCountdown(int seconds);
void hermesOverlayCancelCountdown(void);
void hermesOverlayFreeString(char *s);
void hermesOverlayRun(void);
void hermesOverlayShowSettings(const char *apiKey, const char *provider, bool stealth, bool humanise, int delayMs, const char *resumeProfile, const char *speechLocale);
void hermesOverlayHideSettings(void);
void hermesOverlayMove(int dx, int dy);
*/
import "C"
import (
	"time"
	"unsafe"

	"github.com/hermes/hermes/internal/config"
	"github.com/hermes/hermes/internal/llm"
)

// Overlay is the native command bar surface.
type Overlay interface {
	BeginAnswer()
	AppendAnswer(delta string)
	FinalizeAnswer(a llm.Answer)
	Instruction() string
	SetInstruction(text string, volatile bool)
	Countdown(seconds int)
	SetIndicator(canSend bool, clearsIn time.Duration)
	SetBusy(on bool)
	SetTrayCount(n int)
	SetAnswerCount(n int)
	SetStealth(on bool)
	OnCapture(handler func())
	OnSend(handler func())
	OnNewSession(handler func())
	OnListenToggle(handler func(on bool))
	OnSettings(handler func())
	OnTypeReady(handler func())
	OnSettingsSaved(handler func(apiKey, provider string, stealth, humanise bool, delay time.Duration, resumeProfile, speechLocale string))
	Show()
	Hide()
	Move(dx, dy int)
}

// CancelCountdown cancels the typing countdown.
func CancelCountdown() {
	C.hermesOverlayCancelCountdown()
}

// Run starts the NSApplication run loop on the main thread.
func Run() {
	C.hermesOverlayRun()
}

// New creates the overlay from config.
// Must be called on the main thread (the OS thread that will run [NSApp run]).
func New(cfg config.Config) Overlay {
	o := &nativeOverlay{}
	currentOverlay = o
	C.hermesOverlayInit(C.bool(cfg.Stealth))
	return o
}

type nativeOverlay struct {
	onCapture      func()
	onSend         func()
	onNewSession   func()
	onListenToggle func(bool)
	onSettings     func()
	onTypeReady    func()
	onSettingsSaved func(apiKey, provider string, stealth, humanise bool, delay time.Duration, resumeProfile, speechLocale string)
}

func (o *nativeOverlay) BeginAnswer() {
	C.hermesOverlayBeginAnswer()
}

func (o *nativeOverlay) AppendAnswer(delta string) {
	c := C.CString(delta)
	defer C.free(unsafe.Pointer(c))
	C.hermesOverlayAppendAnswer(c)
}

func (o *nativeOverlay) FinalizeAnswer(a llm.Answer) {
	c := C.CString(a.Text)
	defer C.free(unsafe.Pointer(c))
	C.hermesOverlayFinalizeAnswer(c)
}

func (o *nativeOverlay) Instruction() string {
	c := C.hermesOverlayGetInstruction()
	if c == nil {
		return ""
	}
	defer C.hermesOverlayFreeString(c)
	return C.GoString(c)
}

func (o *nativeOverlay) SetInstruction(text string, volatile bool) {
	c := C.CString(text)
	defer C.free(unsafe.Pointer(c))
	C.hermesOverlaySetInstruction(c)
}

func (o *nativeOverlay) Countdown(seconds int) {
	C.hermesOverlayCountdown(C.int(seconds))
}

func (o *nativeOverlay) SetIndicator(canSend bool, clearsIn time.Duration) {
	secs := int(clearsIn.Seconds())
	if clearsIn > 0 && secs < 1 {
		secs = 1
	}
	C.hermesOverlaySetIndicator(C.bool(canSend), C.int(secs))
}

func (o *nativeOverlay) SetBusy(on bool) {
	C.hermesOverlaySetBusy(C.bool(on))
}

func (o *nativeOverlay) SetTrayCount(n int) {
	C.hermesOverlaySetTrayCount(C.int(n))
}

func (o *nativeOverlay) SetAnswerCount(n int) {
	C.hermesOverlaySetAnswerCount(C.int(n))
}

func (o *nativeOverlay) SetStealth(on bool) {
	C.hermesOverlaySetStealth(C.bool(on))
}

func (o *nativeOverlay) OnCapture(handler func()) {
	o.onCapture = handler
}

func (o *nativeOverlay) OnSend(handler func()) {
	o.onSend = handler
}

func (o *nativeOverlay) OnNewSession(handler func()) {
	o.onNewSession = handler
}

func (o *nativeOverlay) OnListenToggle(handler func(bool)) {
	o.onListenToggle = handler
}

func (o *nativeOverlay) OnSettings(handler func()) {
	o.onSettings = handler
}

func (o *nativeOverlay) OnTypeReady(handler func()) {
	o.onTypeReady = handler
}

func (o *nativeOverlay) OnSettingsSaved(handler func(apiKey, provider string, stealth, humanise bool, delay time.Duration, resumeProfile, speechLocale string)) {
	o.onSettingsSaved = handler
}

func (o *nativeOverlay) Show() {
	C.hermesOverlayShow()
}

func (o *nativeOverlay) Hide() {
	C.hermesOverlayHide()
}

func HideSettings() {
	C.hermesOverlayHideSettings()
}

func (o *nativeOverlay) Move(dx, dy int) {
	C.hermesOverlayMove(C.int(dx), C.int(dy))
}

// ShowSettings opens the native settings window.
func ShowSettings(cfg config.Config) {
	cKey := C.CString(cfg.APIKey)
	cModel := C.CString(cfg.Model)
	cProfile := C.CString(cfg.ResumeProfile)
	cLocale := C.CString(cfg.SpeechLocale)
	defer C.free(unsafe.Pointer(cKey))
	defer C.free(unsafe.Pointer(cModel))
	defer C.free(unsafe.Pointer(cProfile))
	defer C.free(unsafe.Pointer(cLocale))

	cProvider := C.CString(cfg.Provider)
	defer C.free(unsafe.Pointer(cProvider))
	C.hermesOverlayShowSettings(cKey, cProvider, C.bool(cfg.Stealth), C.bool(cfg.Humanise),
		C.int(int(cfg.BaseDelay.Milliseconds())), cProfile, cLocale)
}

//export hermesOverlayOnCapture
func hermesOverlayOnCapture() {
	if currentOverlay != nil && currentOverlay.onCapture != nil {
		currentOverlay.onCapture()
	}
}

//export hermesOverlayOnSend
func hermesOverlayOnSend() {
	if currentOverlay != nil && currentOverlay.onSend != nil {
		currentOverlay.onSend()
	}
}

//export hermesOverlayOnNewSession
func hermesOverlayOnNewSession() {
	if currentOverlay != nil && currentOverlay.onNewSession != nil {
		currentOverlay.onNewSession()
	}
}

//export hermesOverlayOnListenToggle
func hermesOverlayOnListenToggle(on C.int) {
	if currentOverlay != nil && currentOverlay.onListenToggle != nil {
		currentOverlay.onListenToggle(on != 0)
	}
}

//export hermesOverlayOnSettings
func hermesOverlayOnSettings() {
	if currentOverlay != nil && currentOverlay.onSettings != nil {
		currentOverlay.onSettings()
	}
}

//export hermesOverlayOnTypeReady
func hermesOverlayOnTypeReady() {
	if currentOverlay != nil && currentOverlay.onTypeReady != nil {
		currentOverlay.onTypeReady()
	}
}

//export hermesOverlayOnSettingsSaved
func hermesOverlayOnSettingsSaved(apiKey *C.char, provider *C.char, stealth C.int, humanise C.int, delayMs C.int, resumeProfile *C.char, speechLocale *C.char) {
	if currentOverlay != nil && currentOverlay.onSettingsSaved != nil {
		currentOverlay.onSettingsSaved(
			C.GoString(apiKey),
			C.GoString(provider),
			stealth != 0,
			humanise != 0,
			time.Duration(delayMs)*time.Millisecond,
			C.GoString(resumeProfile),
			C.GoString(speechLocale),
		)
	}
}

var currentOverlay *nativeOverlay

func init() {
	currentOverlay = &nativeOverlay{}
}
