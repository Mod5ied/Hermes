// Hermes: capture, answer, type.
package main

import (
	"context"
	"fmt"
	"log"
	"os"
	"runtime"
	"syscall"
	"time"

	"github.com/hermes/hermes/internal/capture"
	"github.com/hermes/hermes/internal/config"
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

func main() {
	// Temporary diagnostic logging to disk because stderr is lost when the
	// app is launched via open(1).
	if f, err := os.OpenFile("/tmp/hermes.log", os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0644); err == nil {
		log.SetOutput(f)
		os.Stderr = f
		// Also redirect C's stderr (file descriptor 2) so Objective-C logs
		// written with fprintf(stderr, ...) end up in the same file.
		_ = syscall.Dup2(int(f.Fd()), 2)
	}

	// Pin the main goroutine to the true OS main thread so that
	// [NSApp run] starts AppKit's event loop on the correct thread.
	runtime.LockOSThread()
	run()
}

func run() {
	cfg, err := config.Load()
	if err != nil {
		log.Fatalf("load config: %v", err)
	}

	config.ApplyProviderDefaults(&cfg)

	var passBalancePct int
	var onPassBalance func(int)

	thread := session.NewThreadFromConfig(cfg)
	tracker := ratelimit.NewTracker(cfg.Model)
	typerEngine := typer.New(typer.Options{BaseDelay: cfg.BaseDelay, Humanise: cfg.Humanise})
	tray := tray.New()
	transcriber := speech.New(cfg.SpeechLocale)
	ovl := overlay.New(cfg)
	permissions.EnsureAll()
	ovl.SetOpacity(cfg.OverlayOpacity)

	onPassBalance = func(pct int) {
		passBalancePct = pct
		ovl.SetPassBalance(true, pct)
	}

	// Refresh the pass balance on startup so pass mode survives app restarts.
	if cfg.PassActive || pass.Active() {
		if pk, err := pass.PassKey(); err == nil && pk != "" {
			ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
			act, err := pass.Activate(ctx, pass.ResolveWorkerURL(cfg), pk)
			cancel()
			if err == nil {
				passBalancePct = act.BalancePct
				cfg.PassActive = true
				ovl.SetPassBalance(true, act.BalancePct)
			} else {
				log.Printf("startup pass refresh: %v", err)
				if !pass.Active() {
					cfg.PassActive = false
					_ = pass.Clear()
				}
			}
		} else {
			cfg.PassActive = false
			_ = pass.Clear()
		}
	}

	client := newClient(cfg, onPassBalance)

	var answerBuffer string
	var typing bool
	var listening bool
	var selectedHistory int = -1 // index into thread turns while reviewing history

	showCurrentHistory := func() {
		turns := thread.Turns()
		if len(turns) == 0 || selectedHistory < 0 || selectedHistory >= len(turns) {
			selectedHistory = -1
			return
		}
		turn := turns[selectedHistory]
		question := turn.Instruction
		if question == "" {
			question = "(screenshot)"
		}
		ovl.ShowHistoryItem(selectedHistory, len(turns), question, turn.Answer, int(turn.AnswerType), thread.IsPinned(selectedHistory))
	}

	moveHistory := func(delta int) {
		turns := thread.Turns()
		if len(turns) == 0 {
			selectedHistory = -1
			return
		}
		selectedHistory += delta
		if selectedHistory < 0 {
			selectedHistory = 0
		}
		if selectedHistory >= len(turns) {
			selectedHistory = len(turns) - 1
		}
		showCurrentHistory()
	}

	togglePin := func() {
		if selectedHistory < 0 {
			return
		}
		pinned, ok := thread.TogglePin(selectedHistory)
		if !ok {
			ovl.Flash("Pin limit is 2")
			return
		}
		ovl.SetItemPinned(selectedHistory, pinned)
		ovl.SetPinnedBadge(thread.PinnedCount())
	}

	updateIndicator := func() {
		if cfg.PassActive {
			ovl.SetPassBalance(passBalancePct > 0, passBalancePct)
			return
		}
		if cfg.APIKey == "" {
			ovl.SetIndicator(false, 0)
			return
		}
		est := ratelimit.EstimateTokens(thread.SystemPrompt(), ovl.Instruction(), tray.Count())
		ok, clearsIn, _ := tracker.CanSend(est)
		ovl.SetIndicator(ok, clearsIn)
	}

	cancelAll := func() {
		typerEngine.Stop()
		overlay.CancelCountdown()
		typing = false
	}

	doCapture := func() {
		// Capture the frontmost application window silently in the background.
		// No overlay, no focus change, and Hermes is never in the shot.
		go func() {
			cancelAll()
			img, err := capture.CaptureFrontWindow()
			if err != nil {
				log.Printf("capture: %v", err)
				return
			}
			dataURL, err := capture.EncodeForGroq(img)
			if err != nil {
				log.Printf("encode: %v", err)
				return
			}
			if _, err := tray.Add(dataURL); err != nil {
				log.Printf("tray: %v", err)
				return
			}
			ovl.SetTrayCount(tray.Count())
		}()
	}

	doSend := func() {
		cancelAll()
		if err := cfg.ValidateSend(); err != nil {
			ovl.AppendAnswer("\n" + err.Error())
			return
		}
		if cfg.PassActive && passBalancePct <= 0 {
			ovl.AppendAnswer("\nPass used up, top up to continue.")
			return
		}

		instruction := ovl.Instruction()
		vision := config.IsVisionModel(cfg.Provider, cfg.Model)
		if !vision && tray.Count() > 0 {
			tray.Clear()
			ovl.SetTrayCount(0)
		}
		if instruction == "" && tray.Count() == 0 {
			return
		}

		if !cfg.PassActive {
			est := ratelimit.EstimateTokens(thread.SystemPrompt(), instruction, tray.Count())
			ok, clearsIn, reason := tracker.CanSend(est)
			if !ok {
				ovl.SetIndicator(false, clearsIn)
				ovl.AppendAnswer("\nRate limited: " + reason + ". Retry in " + ratelimit.FormatDuration(clearsIn))
				return
			}
		}

		current := session.Turn{
			Instruction:   instruction,
			ImageDataURLs: tray.Shots(),
		}
		msgs := thread.Build(current, vision)
		if !cfg.PassActive {
			tracker.RecordSend()
		}
		ovl.SetBusy(true)
		ovl.BeginAnswer()

		// Run the network call off the main thread so the AppKit run loop
		// is not blocked while streaming. Overlay mutators marshal to the
		// main queue internally, so AppendAnswer and the final calls are safe.
		go func() {
			ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
			defer cancel()

			answer, snap, err := client.Solve(ctx, msgs, ovl.AppendAnswer)
			tracker.Update(snap)
			ovl.SetBusy(false)

			if err != nil {
				ovl.FinalizeAnswer(llm.Answer{Type: llm.None, Text: "Error: " + err.Error()})
				return
			}

			current.Answer = answer.Text
			current.AnswerType = answer.Type
			thread.Commit(current)
			if answer.Type == llm.Code {
				thread.SetAutoPin(thread.Len() - 1)
			}
			answerBuffer = answer.Text
			ovl.FinalizeAnswer(answer)
			ovl.SetPinnedBadge(thread.PinnedCount())
			ovl.SetAnswerCount(thread.Len())
			tray.Clear()
			ovl.SetTrayCount(0)
			ovl.SetInstruction("", false)
			transcriber.Reset()
		}()
	}

	doType := func() {
		if answerBuffer == "" || typing {
			return
		}
		typing = true
		ovl.Countdown(5)
	}

	doListenToggle := func(on bool) {
		if on {
			// Start capture on a background goroutine; ScreenCaptureKit setup
			// may block waiting for the main run loop, so we must not hold the
			// UI thread.
			go func() {
				if err := transcriber.Start(func(r speech.Result) {
					ovl.SetInstruction(r.Text, !r.Final)
				}); err != nil {
					log.Printf("speech: %v", err)
					listening = false
					ovl.SetListening(false)
					ovl.Flash("Couldn't capture call audio, try again.")
					return
				}
			}()
		} else {
			_ = transcriber.Stop()
		}
	}

	ovl.OnCapture(doCapture)
	ovl.OnSend(doSend)
	ovl.OnNewSession(func() {
		thread.Clear()
		answerBuffer = ""
		selectedHistory = -1
		tray.Clear()
		ovl.SetTrayCount(0)
		ovl.SetInstruction("", false)
		ovl.SetPinnedBadge(0)
		ovl.ExitHistory()
		transcriber.Reset()
	})
	ovl.OnListenToggle(func(on bool) {
		listening = on
		doListenToggle(on)
	})
	ovl.OnSettings(func() {
		pk, _ := pass.PassKey()
		overlay.ShowSettings(cfg, pk, pass.Active(), passBalancePct)
	})
	ovl.OnTray(func() {
		tray.Clear()
		ovl.SetTrayCount(0)
	})
	ovl.OnResumeUpload(func(path string) (string, error) {
		raw, err := resume.ExtractText(path)
		if err != nil {
			return "", err
		}
		return resume.BuildProfile(raw)
	})
	updateVisionUI := func() {
		vision := config.IsVisionModel(cfg.Provider, cfg.Model)
		ovl.SetCaptureEnabled(vision)
		if vision {
			ovl.SetModelNote("")
		} else {
			ovl.SetModelNote("Model is text-only, screenshots ignored.")
		}
	}

	ovl.OnOpacityChanged(func(pct int) {
		cfg.OverlayOpacity = pct
		if err := config.Save(cfg); err != nil {
			log.Printf("save opacity: %v", err)
		}
	})

	ovl.OnSettingsSaved(func(apiKey, passKey, provider, model string, stealth, humanise bool, delay time.Duration, resumeProfile, speechLocale string) {
		if cfg.APIKeys == nil {
			cfg.APIKeys = map[string]string{}
		}
		cfg.APIKeys[provider] = apiKey
		cfg.APIKey = apiKey
		cfg.Provider = provider
		cfg.Model = model
		cfg.Stealth = stealth
		cfg.Humanise = humanise
		cfg.BaseDelay = delay
		cfg.ResumeProfile = resumeProfile
		cfg.SpeechLocale = speechLocale

		if passKey != "" {
			ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
			act, err := pass.Activate(ctx, pass.ResolveWorkerURL(cfg), passKey)
			cancel()
			if err != nil {
				cfg.PassActive = false
				_ = pass.Clear()
				log.Printf("pass activation: %v", err)
				ovl.Flash("Pass activation failed: " + err.Error())
				ovl.RefreshPassPane(false, 0)
			} else {
				cfg.PassActive = true
				passBalancePct = act.BalancePct
				ovl.SetPassBalance(true, act.BalancePct)
				ovl.Flash(fmt.Sprintf("Pass active - %d%%", act.BalancePct))
				ovl.RefreshPassPane(true, act.BalancePct)
			}
		} else if cfg.PassActive {
			cfg.PassActive = false
			passBalancePct = 0
			_ = pass.Clear()
			ovl.RefreshPassPane(false, 0)
		}

		config.ApplyProviderDefaults(&cfg)
		if err := config.Save(cfg); err != nil {
			log.Printf("save settings: %v", err)
		}
		client = newClient(cfg, onPassBalance)
		thread = session.NewThreadFromConfig(cfg)
		typerEngine = typer.New(typer.Options{BaseDelay: cfg.BaseDelay, Humanise: cfg.Humanise})
		ovl.SetStealth(cfg.Stealth)
		updateVisionUI()
		updateIndicator()
	})
	ovl.OnType(doType)
	ovl.OnTypeReady(func() {
		if typing {
			_ = typerEngine.Type(answerBuffer)
			typing = false
		}
	})
	ovl.OnHistoryEnter(func() {
		turns := thread.Turns()
		if len(turns) == 0 {
			selectedHistory = -1
			return
		}
		selectedHistory = len(turns) - 1
		showCurrentHistory()
	})
	ovl.OnHistoryPrev(func() { moveHistory(-1) })
	ovl.OnHistoryNext(func() { moveHistory(+1) })
	ovl.OnPinToggle(togglePin)
	ovl.OnHistoryExit(func() {
		selectedHistory = -1
		ovl.ExitHistory()
	})

	updateVisionUI()

	// Hotkeys - register off the main goroutine. golang.design/x/hotkey
	// internally dispatch_sync()s to the main queue to install its event tap.
	// If we call that from the main thread before [NSApp run] starts, GCD can
	// deadlock or abort. Running registration from a background goroutine lets
	// the dispatch_sync block until the AppKit run loop is spinning.
	go func() {
		register := func(combo string, fn func()) {
			log.Printf("registering hotkey %s", combo)
			if _, err := hotkey.Register(combo, fn); err != nil {
				log.Printf("hotkey disabled (%s): %v", combo, err)
			} else {
				log.Printf("hotkey registered %s", combo)
			}
		}
		register(hotkey.Capture, doCapture)
		register(hotkey.Send, doSend)
		register(hotkey.TypeAnswer, doType)
		register(hotkey.ToggleListen, func() {
			listening = !listening
			doListenToggle(listening)
		})
		register(hotkey.PinToggle, togglePin)
		register(hotkey.Cancel, cancelAll)
		const step = 20
		register(hotkey.MoveLeft, func() { ovl.Move(-step, 0) })
		register(hotkey.MoveRight, func() { ovl.Move(step, 0) })
		register(hotkey.MoveUp, func() { ovl.Move(0, step) })
		register(hotkey.MoveDown, func() { ovl.Move(0, -step) })
		log.Printf("hotkeys done")
	}()

	// Rate-limit indicator ticker.
	go func() {
		ticker := time.NewTicker(500 * time.Millisecond)
		defer ticker.Stop()
		for range ticker.C {
			updateIndicator()
		}
	}()

	ovl.Show()
	log.Printf("starting NSApp run loop")
	overlay.Run()
	log.Printf("NSApp run loop exited")
}

func newClient(cfg config.Config, onBalance func(int)) llm.Client {
	return llm.New(cfg, onBalance)
}
