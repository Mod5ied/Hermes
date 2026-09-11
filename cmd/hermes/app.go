package main

import (
	"context"
	"errors"
	"fmt"
	"image"
	"log"
	"strings"
	"sync/atomic"
	"time"

	"github.com/hermes/hermes/internal/capture"
	"github.com/hermes/hermes/internal/config"
	"github.com/hermes/hermes/internal/documentcontext"
	"github.com/hermes/hermes/internal/hotkey"
	"github.com/hermes/hermes/internal/llm"
	"github.com/hermes/hermes/internal/overlay"
	"github.com/hermes/hermes/internal/pass"
	"github.com/hermes/hermes/internal/permissions"
	"github.com/hermes/hermes/internal/ratelimit"
	"github.com/hermes/hermes/internal/resume"
	"github.com/hermes/hermes/internal/session"
	"github.com/hermes/hermes/internal/speech"
	"github.com/hermes/hermes/internal/tray"
	"github.com/hermes/hermes/internal/typer"
)

type application struct {
	cfg              config.Config
	passBalancePct   int
	thread           *session.Thread
	documentThread   *session.Thread
	discussionThread *session.Thread
	documents        *documentcontext.Store
	tracker          *ratelimit.Tracker
	typerEngine      typer.Typer
	tray             *tray.Tray
	transcriber      speech.Transcriber
	overlay          overlay.Overlay
	client           llm.Client
	answerBuffer     string
	typing           bool
	listening        bool
	capturesInFlight atomic.Int32
	selectedHistory  int
	discussionMode   bool
	questionRequest  bool
	stealthChanged   func(bool)
}

type sendRequest struct {
	current      session.Turn
	messages     []llm.Message
	thread       *session.Thread
	documentMode bool
	questions    bool
}

var errCaptureCancelled = errors.New("capture region selection cancelled")

func run() {
	app := initializeApplication()
	app.overlay.Show()
	log.Printf("starting NSApp run loop")
	overlay.Run()
	log.Printf("NSApp run loop exited")
}

func initializeApplication() *application {
	return initializeApplicationWithPassRefresh(true)
}

func initializeApplicationWithPassRefresh(refreshPass bool) *application {
	cfg, err := config.Load()
	if err != nil {
		log.Fatalf("load config: %v", err)
	}
	config.ApplyProviderDefaults(&cfg)
	app := newApplication(cfg)
	permissions.EnsureAll()
	app.applyDisplaySettings()
	if refreshPass {
		app.refreshPassAtStartup()
	}
	app.client = newClient(app.cfg, app.onPassBalance)
	app.bindOverlayHandlers()
	app.updateDocumentSummary()
	app.updateVisionUI()
	app.startHotkeys()
	app.startIndicatorTicker()
	return app
}

func newApplication(cfg config.Config) *application {
	return &application{
		cfg:              cfg,
		thread:           session.NewThreadFromConfig(cfg),
		documentThread:   session.NewThread(cfg.ContextTurns, cfg.ImageWindow, llm.DocumentTaskSystemPrompt()),
		discussionThread: session.NewThread(discussionHistoryLimit(cfg.ContextTurns), 0, llm.DiscussionSystemPrompt()),
		documents:        documentcontext.New(),
		tracker:          ratelimit.NewTracker(cfg.Model),
		typerEngine:      typer.New(typer.Options{BaseDelay: cfg.BaseDelay, Humanise: cfg.Humanise}),
		tray:             tray.New(),
		transcriber:      speech.New(cfg.SpeechLocale),
		overlay:          overlay.New(cfg),
		selectedHistory:  -1,
	}
}

func (a *application) applyDisplaySettings() {
	a.overlay.SetOpacity(a.cfg.OverlayOpacity)
	a.overlay.SetFontSize(a.cfg.AnswerFontSize)
}

func (a *application) onPassBalance(pct int) {
	a.passBalancePct = pct
	a.overlay.SetPassBalance(true, pct)
}

func (a *application) refreshPassAtStartup() {
	if !a.shouldRefreshPass() {
		return
	}
	passKey, ok := storedPassKey()
	if !ok {
		a.disablePass()
		return
	}
	activation, err := activatePass(a.cfg, passKey)
	if err != nil {
		a.handleStartupPassError(err)
		return
	}
	a.cfg.PassActive = true
	a.onPassBalance(activation.BalancePct)
}

func (a *application) shouldRefreshPass() bool {
	return a.cfg.PassActive || pass.Active()
}

func storedPassKey() (string, bool) {
	passKey, err := pass.PassKey()
	return passKey, err == nil && passKey != ""
}

func activatePass(cfg config.Config, passKey string) (*pass.Activation, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	return pass.Activate(ctx, pass.ResolveWorkerURL(cfg), passKey)
}

func (a *application) handleStartupPassError(err error) {
	log.Printf("startup pass refresh: %v", err)
	if !pass.Active() {
		a.disablePass()
	}
}

func (a *application) disablePass() {
	a.cfg.PassActive = false
	a.passBalancePct = 0
	_ = pass.Clear()
}

func (a *application) activeThread() *session.Thread {
	if a.discussionMode {
		return a.discussionThread
	}
	if a.documents.Summary().Count > 0 {
		return a.documentThread
	}
	return a.thread
}

func (a *application) updateDocumentSummary() {
	summary := a.documents.Summary()
	a.overlay.SetDocumentContext(summary.Count, summary.Bytes, strings.Join(summary.Names, "  •  "))
}

func (a *application) showCurrentHistory() {
	thread := a.activeThread()
	turns := thread.Turns()
	if !validHistoryIndex(a.selectedHistory, len(turns)) {
		a.selectedHistory = -1
		return
	}
	turn := turns[a.selectedHistory]
	question := historyQuestion(turn)
	a.overlay.ShowHistoryItem(a.selectedHistory, len(turns), question, turn.Answer, int(turn.AnswerType), thread.IsPinned(a.selectedHistory))
}

func validHistoryIndex(index, count int) bool {
	return index >= 0 && index < count
}

func historyQuestion(turn session.Turn) string {
	if turn.Instruction == "" {
		return "(screenshot)"
	}
	return turn.Instruction
}

func (a *application) moveHistory(delta int) {
	turns := a.activeThread().Turns()
	if len(turns) == 0 {
		a.selectedHistory = -1
		return
	}
	a.selectedHistory = max(0, min(a.selectedHistory+delta, len(turns)-1))
	a.showCurrentHistory()
}

func (a *application) historyPrevious() { a.moveHistory(-1) }
func (a *application) historyNext()     { a.moveHistory(1) }

func (a *application) togglePin() {
	if a.selectedHistory < 0 {
		return
	}
	thread := a.activeThread()
	pinned, ok := thread.TogglePin(a.selectedHistory)
	if !ok {
		a.overlay.Flash("Pin limit is 2")
		return
	}
	a.overlay.SetItemPinned(a.selectedHistory, pinned)
	a.overlay.SetPinnedBadge(thread.PinnedCount())
}

func (a *application) updateIndicator() {
	if a.cfg.PassActive {
		a.overlay.SetPassBalance(a.passBalancePct > 0, a.passBalancePct)
		return
	}
	if a.cfg.APIKey == "" {
		a.overlay.SetIndicator(false, 0)
		return
	}
	documentText := ""
	if a.documents.Summary().Count > 0 {
		documentText = a.documents.PromptBlock()
	}
	thread := a.activeThread()
	estimate := ratelimit.EstimateTokens(thread.SystemPrompt(), a.overlay.Instruction()+documentText, a.tray.Count())
	ok, clearsIn, _ := a.tracker.CanSend(estimate)
	a.overlay.SetIndicator(ok, clearsIn)
}

func (a *application) cancelAll() {
	a.typerEngine.Stop()
	overlay.CancelCountdown()
	a.typing = false
}

func (a *application) doCapture() {
	a.capturesInFlight.Add(1)
	a.overlay.Flash("Capturing screenshot...")
	go a.captureAndStore()
}

func (a *application) captureAndStore() {
	defer a.capturesInFlight.Add(-1)
	a.cancelAll()
	image, err := a.captureTarget()
	if err != nil {
		if errors.Is(err, errCaptureCancelled) {
			return
		}
		a.reportScreenshotError("capture", err)
		return
	}
	bounds := image.Bounds()
	dataURL, err := capture.EncodeForGroq(image)
	if err != nil {
		a.reportScreenshotError("encode", err)
		return
	}
	log.Printf("Hermes capture: encoded %dx%d image as %d-byte data URL", bounds.Dx(), bounds.Dy(), len(dataURL))
	if _, err := a.tray.Add(dataURL); err != nil {
		a.reportScreenshotError("tray", err)
		return
	}
	a.overlay.SetTrayCount(a.tray.Count())
}

func (a *application) captureTarget() (image.Image, error) {
	region, err := a.captureRegion()
	if err != nil {
		return nil, err
	}
	if region == nil {
		return nil, errCaptureCancelled
	}
	img, err := capture.CaptureImage(capture.Rect{X: region.X, Y: region.Y, W: region.W, H: region.H})
	if err != nil {
		return nil, err
	}
	if err := capture.ValidateImageContent(img); err != nil {
		return nil, err
	}
	return img, nil
}

func (a *application) captureRegion() (*config.Rect, error) {
	if a.cfg.Region != nil && a.cfg.Region.W > 0 && a.cfg.Region.H > 0 {
		return a.cfg.Region, nil
	}
	r, ok, err := capture.SelectRegion(capture.Rect{})
	if err != nil {
		return nil, err
	}
	if !ok {
		return nil, errCaptureCancelled
	}
	a.cfg.Region = &config.Rect{X: r.X, Y: r.Y, W: r.W, H: r.H}
	if err := config.Save(a.cfg); err != nil {
		return nil, fmt.Errorf("save capture region: %w", err)
	}
	return a.cfg.Region, nil
}

func (a *application) reselectCaptureRegion() {
	a.cfg.Region = nil
	a.doCapture()
}

func (a *application) reportScreenshotError(stage string, err error) {
	log.Printf("%s: %v", stage, err)
	a.overlay.Flash("Screenshot failed: " + err.Error())
}

func (a *application) doSend() {
	a.cancelAll()
	if !a.canBeginSend() {
		return
	}
	request, ok := a.prepareSend()
	if !ok || !a.allowSend(request) {
		return
	}
	a.recordSendIfNeeded()
	a.overlay.SetBusy(true)
	a.overlay.BeginAnswer()
	go a.solve(request)
}

func (a *application) canBeginSend() bool {
	if a.capturesInFlight.Load() > 0 {
		a.overlay.Flash("Screenshot is still capturing. Send again when the badge appears.")
		return false
	}
	if err := a.cfg.ValidateSend(); err != nil {
		a.overlay.AppendAnswer("\n" + err.Error())
		return false
	}
	if a.cfg.PassActive && a.passBalancePct <= 0 {
		a.overlay.AppendAnswer("\nPass used up, top up to continue.")
		return false
	}
	return true
}

func (a *application) prepareSend() (sendRequest, bool) {
	instruction := a.overlay.Instruction()
	documentMode := a.documents.Summary().Count > 0
	discussionMode := a.discussionMode
	if discussionMode && !documentMode {
		a.overlay.Flash("Attach document context before sending in Discussion Mode")
		return sendRequest{}, false
	}
	vision := config.IsVisionModel(a.cfg.Provider, a.cfg.Model) && !discussionMode
	if !vision && a.tray.Count() > 0 {
		a.clearTray()
	}
	if noSendInput(instruction, a.tray.Count(), documentMode, discussionMode) {
		return sendRequest{}, false
	}
	thread := a.activeThread()
	current := session.Turn{Instruction: instruction, ImageDataURLs: a.tray.Shots()}
	return sendRequest{
		current: current, messages: buildMessages(thread, current, a.documents.PromptBlock(), vision, documentMode, discussionMode, a.questionRequest),
		thread: thread, documentMode: documentMode, questions: a.questionRequest,
	}, true
}

func noSendInput(instruction string, trayCount int, documentMode, discussionMode bool) bool {
	if discussionMode {
		return strings.TrimSpace(instruction) == ""
	}
	return instruction == "" && trayCount == 0 && !documentMode
}

func buildMessages(thread *session.Thread, current session.Turn, documents string, vision, documentMode, discussionMode, questions bool) []llm.Message {
	if questions {
		return thread.BuildDiscussionQuestions(current, documents)
	}
	if discussionMode {
		return thread.BuildDiscussionTask(current, documents)
	}
	if documentMode {
		return thread.BuildDocumentTask(current, documents, vision)
	}
	return thread.Build(current, vision)
}

func (a *application) allowSend(request sendRequest) bool {
	if a.cfg.PassActive {
		return true
	}
	documents := ""
	if request.documentMode {
		documents = a.documents.PromptBlock()
	}
	estimate := ratelimit.EstimateTokens(request.thread.SystemPrompt(), request.current.Instruction+documents, a.tray.Count())
	ok, clearsIn, reason := a.tracker.CanSend(estimate)
	if !ok {
		a.overlay.SetIndicator(false, clearsIn)
		a.overlay.AppendAnswer("\nRate limited: " + reason + ". Retry in " + ratelimit.FormatDuration(clearsIn))
	}
	return ok
}

func (a *application) recordSendIfNeeded() {
	if !a.cfg.PassActive {
		a.tracker.RecordSend()
	}
}

func (a *application) solve(request sendRequest) {
	ctx, cancel := context.WithTimeout(context.Background(), sendTimeout(request.documentMode))
	defer cancel()
	answer, snapshot, err := a.client.Solve(ctx, request.messages, a.deltaHandler(request))
	a.tracker.Update(snapshot)
	a.overlay.SetBusy(false)
	if err != nil {
		a.overlay.FinalizeAnswer(llm.Answer{Type: llm.None, Text: "Error: " + err.Error()})
		return
	}
	a.commitAnswer(request, answerForRequest(request, answer))
}

func sendTimeout(documentMode bool) time.Duration {
	if documentMode {
		return 3 * time.Minute
	}
	return 60 * time.Second
}

func (a *application) commitAnswer(request sendRequest, answer llm.Answer) {
	request.current.Answer = answer.Text
	request.current.AnswerType = answer.Type
	request.thread.Commit(request.current)
	if answer.Type == llm.Code {
		request.thread.SetAutoPin(request.thread.Len() - 1)
	}
	a.answerBuffer = answer.Text
	a.overlay.FinalizeAnswer(answer)
	a.overlay.SetPinnedBadge(request.thread.PinnedCount())
	a.overlay.SetAnswerCount(request.thread.Len())
	a.clearTray()
	a.overlay.SetInstruction("", false)
	a.transcriber.Reset()
}

func (a *application) doType() {
	if a.answerBuffer == "" || a.typing {
		return
	}
	a.typing = true
	a.overlay.Countdown(5)
}

func (a *application) typeReady() {
	if !a.typing {
		return
	}
	_ = a.typerEngine.Type(a.answerBuffer)
	a.typing = false
}

func (a *application) listenToggle(on bool) {
	a.listening = on
	a.overlay.SetListening(on)
	if on {
		go a.startListening()
		return
	}
	go func() {
		if err := a.transcriber.Stop(); err != nil {
			log.Printf("stop speech: %v", err)
		}
	}()
}

func (a *application) toggleListening() {
	a.listening = !a.listening
	a.listenToggle(a.listening)
}

func (a *application) startListening() {
	if err := a.transcriber.Start(a.onSpeechResult); err != nil {
		log.Printf("speech: %v", err)
		a.listening = false
		a.overlay.SetListening(false)
		a.overlay.Flash("Couldn't capture call audio, try again.")
	}
}

func (a *application) onSpeechResult(result speech.Result) {
	a.overlay.SetInstruction(result.Text, !result.Final)
}

func (a *application) bindOverlayHandlers() {
	a.overlay.OnCapture(a.doCapture)
	a.overlay.OnSend(a.doSend)
	a.overlay.OnNewSession(a.newSession)
	a.overlay.OnListenToggle(a.listenToggle)
	a.overlay.OnSettings(a.showSettings)
	a.overlay.OnTray(a.clearTray)
	a.overlay.OnDocumentPaste(a.addDocumentPaste)
	a.overlay.OnDocumentFile(a.addDocumentFile)
	a.overlay.OnDocumentClear(a.clearDocuments)
	a.overlay.OnDiscussionToggle(a.toggleDiscussionMode)
	a.overlay.OnAskQuestions(a.askQuestions)
	a.overlay.OnResumeUpload(a.uploadResume)
	a.overlay.OnOpacityChanged(a.changeOpacity)
	a.overlay.OnFontSizeChanged(a.changeFontSize)
	a.overlay.OnSettingsSaved(a.saveSettings)
	a.overlay.OnType(a.doType)
	a.overlay.OnTypeReady(a.typeReady)
	a.overlay.OnHistoryEnter(a.enterHistory)
	a.overlay.OnHistoryPrev(a.historyPrevious)
	a.overlay.OnHistoryNext(a.historyNext)
	a.overlay.OnPinToggle(a.togglePin)
	a.overlay.OnHistoryExit(a.exitHistory)
}

func (a *application) newSession() {
	a.thread.Clear()
	a.documentThread.Clear()
	a.discussionThread.Clear()
	a.documents.Clear()
	a.setDiscussionMode(false)
	a.answerBuffer = ""
	a.selectedHistory = -1
	a.clearTray()
	a.overlay.SetInstruction("", false)
	a.overlay.SetPinnedBadge(0)
	a.updateDocumentSummary()
	a.overlay.ExitHistory()
	a.transcriber.Reset()
}

func (a *application) showSettings() {
	passKey, _ := pass.PassKey()
	overlay.ShowSettings(a.cfg, passKey, pass.Active(), a.passBalancePct)
}

func (a *application) clearTray() {
	a.tray.Clear()
	a.overlay.SetTrayCount(0)
}

func (a *application) addDocumentPaste(text string) error {
	wasEmpty := a.documents.Summary().Count == 0
	if err := a.documents.AddPaste(text); err != nil {
		return err
	}
	a.afterDocumentAdded(wasEmpty)
	return nil
}

func (a *application) addDocumentFile(path string) error {
	wasEmpty := a.documents.Summary().Count == 0
	if err := a.documents.AddFile(path); err != nil {
		return err
	}
	a.afterDocumentAdded(wasEmpty)
	return nil
}

func (a *application) afterDocumentAdded(wasEmpty bool) {
	if wasEmpty {
		a.selectedHistory = -1
		a.overlay.ExitHistory()
		a.overlay.SetAnswerCount(a.documentThread.Len())
		a.overlay.SetPinnedBadge(a.documentThread.PinnedCount())
	}
	a.updateDocumentSummary()
	a.updateIndicator()
}

func (a *application) clearDocuments() {
	a.documents.Clear()
	a.documentThread.Clear()
	a.discussionThread.Clear()
	a.setDiscussionMode(false)
	a.selectedHistory = -1
	a.overlay.ExitHistory()
	a.overlay.SetAnswerCount(a.thread.Len())
	a.overlay.SetPinnedBadge(a.thread.PinnedCount())
	a.updateDocumentSummary()
	a.updateIndicator()
}

func (a *application) uploadResume(path string) (string, error) {
	raw, err := resume.ExtractText(path)
	if err != nil {
		return "", err
	}
	return resume.BuildProfile(raw)
}

func (a *application) changeOpacity(pct int) {
	a.cfg.OverlayOpacity = pct
	if err := config.Save(a.cfg); err != nil {
		log.Printf("save opacity: %v", err)
	}
}

func (a *application) changeFontSize(pt int) {
	a.cfg.AnswerFontSize = pt
	if err := config.Save(a.cfg); err != nil {
		log.Printf("save font size: %v", err)
	}
}

func (a *application) saveSettings(apiKey, passKey, provider, model string, stealth, humanise bool, delay time.Duration, resumeProfile, speechLocale string) {
	a.applySettings(apiKey, provider, model, stealth, humanise, delay, resumeProfile, speechLocale)
	a.updatePassSetting(passKey)
	config.ApplyProviderDefaults(&a.cfg)
	if err := config.Save(a.cfg); err != nil {
		log.Printf("save settings: %v", err)
	}
	a.reconfigure()
	if a.stealthChanged != nil {
		a.stealthChanged(stealth)
	}
}

func (a *application) applySettings(apiKey, provider, model string, stealth, humanise bool, delay time.Duration, resumeProfile, speechLocale string) {
	if a.cfg.APIKeys == nil {
		a.cfg.APIKeys = map[string]string{}
	}
	a.cfg.APIKeys[provider] = apiKey
	a.cfg.APIKey = apiKey
	a.cfg.Provider = provider
	a.cfg.Model = model
	a.cfg.Stealth = stealth
	a.cfg.Humanise = humanise
	a.cfg.BaseDelay = delay
	a.cfg.ResumeProfile = resumeProfile
	a.cfg.SpeechLocale = speechLocale
}

func (a *application) updatePassSetting(passKey string) {
	if passKey != "" {
		a.activatePassSetting(passKey)
		return
	}
	if a.cfg.PassActive {
		a.disablePass()
		a.overlay.RefreshPassPane(false, 0)
	}
}

func (a *application) activatePassSetting(passKey string) {
	activation, err := activatePass(a.cfg, passKey)
	if err != nil {
		a.disablePass()
		log.Printf("pass activation: %v", err)
		a.overlay.Flash("Pass activation failed: " + err.Error())
		a.overlay.RefreshPassPane(false, 0)
		return
	}
	a.cfg.PassActive = true
	a.onPassBalance(activation.BalancePct)
	a.overlay.Flash(fmt.Sprintf("Pass active - %d%%", activation.BalancePct))
	a.overlay.RefreshPassPane(true, activation.BalancePct)
}

func (a *application) reconfigure() {
	a.client = newClient(a.cfg, a.onPassBalance)
	a.thread = session.NewThreadFromConfig(a.cfg)
	a.documentThread = session.NewThread(a.cfg.ContextTurns, a.cfg.ImageWindow, llm.DocumentTaskSystemPrompt())
	a.discussionThread = session.NewThread(discussionHistoryLimit(a.cfg.ContextTurns), 0, llm.DiscussionSystemPrompt())
	a.tracker = ratelimit.NewTracker(a.cfg.Model)
	a.selectedHistory = -1
	a.overlay.ExitHistory()
	a.overlay.SetAnswerCount(a.activeThread().Len())
	a.overlay.SetPinnedBadge(a.activeThread().PinnedCount())
	a.typerEngine = typer.New(typer.Options{BaseDelay: a.cfg.BaseDelay, Humanise: a.cfg.Humanise})
	a.overlay.SetStealth(a.cfg.Stealth)
	a.updateVisionUI()
	a.updateIndicator()
}

func (a *application) updateVisionUI() {
	a.overlay.SetCaptureEnabled(config.IsVisionModel(a.cfg.Provider, a.cfg.Model))
}

func (a *application) enterHistory() {
	turns := a.activeThread().Turns()
	if len(turns) == 0 {
		a.selectedHistory = -1
		return
	}
	a.selectedHistory = len(turns) - 1
	a.showCurrentHistory()
}

func (a *application) exitHistory() {
	a.selectedHistory = -1
	a.overlay.ExitHistory()
}

func (a *application) startHotkeys() { go a.registerHotkeys() }

func (a *application) registerHotkeys() {
	a.registerHotkey(hotkey.Capture, a.doCapture)
	a.registerHotkey(hotkey.ReselectCapture, a.reselectCaptureRegion)
	a.registerHotkey(hotkey.Discussion, a.toggleDiscussionMode)
	a.registerHotkey(hotkey.AskQuestions, a.askQuestions)
	a.registerHotkey(hotkey.Send, a.doSend)
	a.registerHotkey(hotkey.TypeAnswer, a.doType)
	a.registerHotkey(hotkey.ToggleListen, a.toggleListening)
	a.registerHotkey(hotkey.PinToggle, a.togglePin)
	a.registerHotkey(hotkey.Cancel, a.cancelAll)
	a.registerHotkey(hotkey.MoveLeft, a.moveLeft)
	a.registerHotkey(hotkey.MoveRight, a.moveRight)
	a.registerHotkey(hotkey.MoveUp, a.moveUp)
	a.registerHotkey(hotkey.MoveDown, a.moveDown)
	log.Printf("hotkeys done")
}

func (a *application) registerHotkey(combo string, handler func()) {
	log.Printf("registering hotkey %s", combo)
	if _, err := hotkey.Register(combo, handler); err != nil {
		log.Printf("hotkey disabled (%s): %v", combo, err)
		return
	}
	log.Printf("hotkey registered %s", combo)
}

const moveStep = 20

func (a *application) moveLeft()  { a.overlay.Move(-moveStep, 0) }
func (a *application) moveRight() { a.overlay.Move(moveStep, 0) }
func (a *application) moveUp()    { a.overlay.Move(0, moveStep) }
func (a *application) moveDown()  { a.overlay.Move(0, -moveStep) }

func (a *application) startIndicatorTicker() { go a.runIndicatorTicker() }

func (a *application) runIndicatorTicker() {
	ticker := time.NewTicker(500 * time.Millisecond)
	defer ticker.Stop()
	for range ticker.C {
		a.updateIndicator()
	}
}

func newClient(cfg config.Config, onBalance func(int)) llm.Client {
	return llm.New(cfg, onBalance)
}
