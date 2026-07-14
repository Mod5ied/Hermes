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
void hermesOverlaySetOpacity(int pct);
void hermesOverlaySetInstruction(const char *text);
char *hermesOverlayGetInstruction(void);
void hermesOverlayAppendInstruction(const char *text, bool final);
void hermesOverlayBeginAnswer(void);
void hermesOverlayAppendAnswer(const char *delta);
void hermesOverlayFinalizeAnswer(const char *text, int type);
void hermesOverlaySetIndicator(bool canSend, int clearsInSeconds);
void hermesOverlaySetPassBalance(bool active, int pct);
void hermesOverlaySetBusy(bool on);
void hermesOverlaySetTrayCount(int n);
void hermesOverlaySetAnswerCount(int n);
void hermesOverlayCountdown(int seconds);
void hermesOverlayCancelCountdown(void);
void hermesOverlayFreeString(char *s);
void hermesOverlayRun(void);
void hermesOverlayShowSettings(const char *apiKey, const char *provider, const char *model, const char *settingsJSON, bool stealth, bool humanise, int delayMs, const char *resumeProfile, const char *speechLocale, const char *passKey, bool passActive, int passPct, int opacity);
void hermesOverlaySetModelNote(const char *msg);
void hermesOverlaySetCaptureEnabled(bool enabled);
void hermesOverlayHideSettings(void);
void hermesOverlayMove(int dx, int dy);
void hermesOverlayEnterHistory(void);
void hermesOverlayShowHistoryItem(int index, int total, const char *question, const char *answerPreview, int answerType, bool pinned);
void hermesOverlaySetItemPinned(int index, bool pinned);
void hermesOverlaySetPinnedBadge(int n);
void hermesOverlayFlash(const char *msg);
void hermesOverlayExitHistory(void);
*/
import "C"
import (
	"encoding/json"
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
	SetPassBalance(active bool, pct int)
	SetBusy(on bool)
	SetTrayCount(n int)
	SetAnswerCount(n int)
	SetStealth(on bool)
	SetOpacity(pct int)
	OnOpacityChanged(handler func(pct int))
	OnCapture(handler func())
	OnSend(handler func())
	OnNewSession(handler func())
	OnListenToggle(handler func(on bool))
	OnSettings(handler func())
	OnType(handler func())
	OnTypeReady(handler func())
	OnSettingsSaved(handler func(apiKey, passKey, provider, model string, stealth, humanise bool, delay time.Duration, resumeProfile, speechLocale string))
	SetModelNote(msg string)
	SetCaptureEnabled(enabled bool)
	OnHistoryEnter(handler func())
	OnHistoryPrev(handler func())
	OnHistoryNext(handler func())
	OnPinToggle(handler func())
	OnHistoryExit(handler func())
	EnterHistory()
	ExitHistory()
	ShowHistoryItem(index, total int, question, answerPreview string, answerType int, pinned bool)
	SetItemPinned(index int, pinned bool)
	SetPinnedBadge(n int)
	Flash(msg string)
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
	onType         func()
	onTypeReady    func()
	onSettingsSaved func(apiKey, passKey, provider, model string, stealth, humanise bool, delay time.Duration, resumeProfile, speechLocale string)
	onOpacityChanged func(pct int)
	onHistoryEnter func()
	onHistoryPrev  func()
	onHistoryNext  func()
	onPinToggle    func()
	onHistoryExit  func()
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
	C.hermesOverlayFinalizeAnswer(c, C.int(a.Type))
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

func (o *nativeOverlay) SetPassBalance(active bool, pct int) {
	C.hermesOverlaySetPassBalance(C.bool(active), C.int(pct))
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

func (o *nativeOverlay) SetOpacity(pct int) {
	C.hermesOverlaySetOpacity(C.int(pct))
}

func (o *nativeOverlay) OnOpacityChanged(handler func(pct int)) {
	o.onOpacityChanged = handler
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

func (o *nativeOverlay) OnType(handler func()) {
	o.onType = handler
}

func (o *nativeOverlay) OnTypeReady(handler func()) {
	o.onTypeReady = handler
}

func (o *nativeOverlay) OnSettingsSaved(handler func(apiKey, passKey, provider, model string, stealth, humanise bool, delay time.Duration, resumeProfile, speechLocale string)) {
	o.onSettingsSaved = handler
}

func (o *nativeOverlay) OnHistoryEnter(handler func()) {
	o.onHistoryEnter = handler
}

func (o *nativeOverlay) OnHistoryPrev(handler func()) {
	o.onHistoryPrev = handler
}

func (o *nativeOverlay) OnHistoryNext(handler func()) {
	o.onHistoryNext = handler
}

func (o *nativeOverlay) OnPinToggle(handler func()) {
	o.onPinToggle = handler
}

func (o *nativeOverlay) OnHistoryExit(handler func()) {
	o.onHistoryExit = handler
}

func (o *nativeOverlay) EnterHistory() {
	C.hermesOverlayEnterHistory()
}

func (o *nativeOverlay) ExitHistory() {
	C.hermesOverlayExitHistory()
}

func (o *nativeOverlay) ShowHistoryItem(index, total int, question, answerPreview string, answerType int, pinned bool) {
	cQuestion := C.CString(question)
	cPreview := C.CString(answerPreview)
	defer C.free(unsafe.Pointer(cQuestion))
	defer C.free(unsafe.Pointer(cPreview))
	C.hermesOverlayShowHistoryItem(C.int(index), C.int(total), cQuestion, cPreview, C.int(answerType), C.bool(pinned))
}

func (o *nativeOverlay) SetItemPinned(index int, pinned bool) {
	C.hermesOverlaySetItemPinned(C.int(index), C.bool(pinned))
}

func (o *nativeOverlay) SetPinnedBadge(n int) {
	C.hermesOverlaySetPinnedBadge(C.int(n))
}

func (o *nativeOverlay) Flash(msg string) {
	c := C.CString(msg)
	defer C.free(unsafe.Pointer(c))
	C.hermesOverlayFlash(c)
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

func (o *nativeOverlay) SetModelNote(msg string) {
	c := C.CString(msg)
	defer C.free(unsafe.Pointer(c))
	C.hermesOverlaySetModelNote(c)
}

func (o *nativeOverlay) SetCaptureEnabled(enabled bool) {
	C.hermesOverlaySetCaptureEnabled(C.bool(enabled))
}

func (o *nativeOverlay) Move(dx, dy int) {
	C.hermesOverlayMove(C.int(dx), C.int(dy))
}

// ShowSettings opens the native settings window.
func ShowSettings(cfg config.Config, passKey string, passActive bool, passPct int) {
	cKey := C.CString(cfg.APIKey)
	cModel := C.CString(cfg.Model)
	cProfile := C.CString(cfg.ResumeProfile)
	cLocale := C.CString(cfg.SpeechLocale)
	cPassKey := C.CString(passKey)
	defer C.free(unsafe.Pointer(cKey))
	defer C.free(unsafe.Pointer(cModel))
	defer C.free(unsafe.Pointer(cProfile))
	defer C.free(unsafe.Pointer(cLocale))
	defer C.free(unsafe.Pointer(cPassKey))

	cProvider := C.CString(cfg.Provider)
	defer C.free(unsafe.Pointer(cProvider))

	type settingsPayload struct {
		Models map[string][]config.ModelInfo `json:"models"`
		Keys   map[string]string             `json:"keys"`
	}
	payload := settingsPayload{Models: config.ProviderModels, Keys: cfg.APIKeys}
	payloadJSON, _ := json.Marshal(payload)
	cPayloadJSON := C.CString(string(payloadJSON))
	defer C.free(unsafe.Pointer(cPayloadJSON))

	C.hermesOverlayShowSettings(cKey, cProvider, cModel, cPayloadJSON, C.bool(cfg.Stealth), C.bool(cfg.Humanise),
		C.int(int(cfg.BaseDelay.Milliseconds())), cProfile, cLocale, cPassKey, C.bool(passActive), C.int(passPct), C.int(cfg.OverlayOpacity))
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

//export hermesOverlayOnType
func hermesOverlayOnType() {
	if currentOverlay != nil && currentOverlay.onType != nil {
		currentOverlay.onType()
	}
}

//export hermesOverlayOnTypeReady
func hermesOverlayOnTypeReady() {
	if currentOverlay != nil && currentOverlay.onTypeReady != nil {
		currentOverlay.onTypeReady()
	}
}

//export hermesOverlayOnHistoryEnter
func hermesOverlayOnHistoryEnter() {
	if currentOverlay != nil && currentOverlay.onHistoryEnter != nil {
		currentOverlay.onHistoryEnter()
	}
}

//export hermesOverlayOnHistoryPrev
func hermesOverlayOnHistoryPrev() {
	if currentOverlay != nil && currentOverlay.onHistoryPrev != nil {
		currentOverlay.onHistoryPrev()
	}
}

//export hermesOverlayOnHistoryNext
func hermesOverlayOnHistoryNext() {
	if currentOverlay != nil && currentOverlay.onHistoryNext != nil {
		currentOverlay.onHistoryNext()
	}
}

//export hermesOverlayOnPinToggle
func hermesOverlayOnPinToggle() {
	if currentOverlay != nil && currentOverlay.onPinToggle != nil {
		currentOverlay.onPinToggle()
	}
}

//export hermesOverlayOnHistoryExit
func hermesOverlayOnHistoryExit() {
	if currentOverlay != nil && currentOverlay.onHistoryExit != nil {
		currentOverlay.onHistoryExit()
	}
}

//export hermesOverlayOnSettingsSaved
func hermesOverlayOnSettingsSaved(apiKey *C.char, passKey *C.char, provider *C.char, model *C.char, stealth C.int, humanise C.int, delayMs C.int, resumeProfile *C.char, speechLocale *C.char) {
	if currentOverlay != nil && currentOverlay.onSettingsSaved != nil {
		currentOverlay.onSettingsSaved(
			C.GoString(apiKey),
			C.GoString(passKey),
			C.GoString(provider),
			C.GoString(model),
			stealth != 0,
			humanise != 0,
			time.Duration(delayMs)*time.Millisecond,
			C.GoString(resumeProfile),
			C.GoString(speechLocale),
		)
	}
}

//export hermesOverlayOnOpacityChanged
func hermesOverlayOnOpacityChanged(pct C.int) {
	if currentOverlay != nil && currentOverlay.onOpacityChanged != nil {
		currentOverlay.onOpacityChanged(int(pct))
	}
}

var currentOverlay *nativeOverlay

func init() {
	currentOverlay = &nativeOverlay{}
}
