// Hermes: capture, answer, type.
package main

import (
	"context"
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
	"github.com/hermes/hermes/internal/permissions"
	"github.com/hermes/hermes/internal/ratelimit"
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
	client := newClient(cfg)
	thread := session.NewThreadFromConfig(cfg)
	tracker := ratelimit.NewTracker(cfg.Model)
	typerEngine := typer.New(typer.Options{BaseDelay: cfg.BaseDelay, Humanise: cfg.Humanise})
	tray := tray.New()
	transcriber := speech.New(cfg.SpeechLocale)
	ovl := overlay.New(cfg)
	permissions.EnsureAll()

	var answerBuffer string
	var typing bool
	var listening bool

	updateIndicator := func() {
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
		cancelAll()
		// Always let the user select the area. The previously saved region is
		// passed as the starting seed so the last selection is pre-selected.
		seed := capture.Rect{}
		if cfg.Region != nil {
			seed = capture.Rect{X: cfg.Region.X, Y: cfg.Region.Y, W: cfg.Region.W, H: cfg.Region.H}
		}
		r, ok, err := capture.SelectRegion(seed)
		if err != nil {
			log.Printf("select region: %v", err)
			return
		}
		if !ok {
			return
		}
		region := &config.Rect{X: r.X, Y: r.Y, W: r.W, H: r.H}
		cfg.Region = region
		_ = config.Save(cfg)

		img, err := capture.CaptureImage(capture.Rect{X: region.X, Y: region.Y, W: region.W, H: region.H})
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
	}

	doSend := func() {
		cancelAll()
		if err := cfg.ValidateSend(); err != nil {
			ovl.AppendAnswer("\n" + err.Error())
			return
		}

		instruction := ovl.Instruction()
		if instruction == "" && tray.Count() == 0 {
			return
		}

		est := ratelimit.EstimateTokens(thread.SystemPrompt(), instruction, tray.Count())
		ok, clearsIn, reason := tracker.CanSend(est)
		if !ok {
			ovl.SetIndicator(false, clearsIn)
			ovl.AppendAnswer("\nRate limited: " + reason + ". Retry in " + ratelimit.FormatDuration(clearsIn))
			return
		}

		current := session.Turn{
			Instruction:   instruction,
			ImageDataURLs: tray.Shots(),
		}
		msgs := thread.Build(current)
		tracker.RecordSend()
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
			thread.Commit(current)
			answerBuffer = answer.Text
			ovl.FinalizeAnswer(answer)
			ovl.SetAnswerCount(thread.Len())
			tray.Clear()
			ovl.SetTrayCount(0)
			ovl.SetInstruction("", false)
			transcriber.Reset()
		}()
	}

	doType := func() {
		if answerBuffer == "" {
			return
		}
		typing = true
		ovl.Countdown(5)
	}

	doListenToggle := func(on bool) {
		if on {
			if err := transcriber.Start(func(r speech.Result) {
				ovl.SetInstruction(r.Text, !r.Final)
			}); err != nil {
				log.Printf("speech: %v", err)
				listening = false
			}
		} else {
			_ = transcriber.Stop()
		}
	}

	ovl.OnCapture(doCapture)
	ovl.OnSend(doSend)
	ovl.OnNewSession(func() {
		thread.Clear()
		answerBuffer = ""
		tray.Clear()
		ovl.SetTrayCount(0)
		ovl.SetInstruction("", false)
		transcriber.Reset()
	})
	ovl.OnListenToggle(func(on bool) {
		listening = on
		doListenToggle(on)
	})
	ovl.OnSettings(func() {
		overlay.ShowSettings(cfg)
	})
	ovl.OnSettingsSaved(func(apiKey, provider string, stealth, humanise bool, delay time.Duration, resumeProfile, speechLocale string) {
		cfg.APIKey = apiKey
		cfg.Provider = provider
		cfg.Stealth = stealth
		cfg.Humanise = humanise
		cfg.BaseDelay = delay
		cfg.ResumeProfile = resumeProfile
		cfg.SpeechLocale = speechLocale
		config.ApplyProviderDefaults(&cfg)
		if err := config.Save(cfg); err != nil {
			log.Printf("save settings: %v", err)
		}
		client = newClient(cfg)
		thread = session.NewThreadFromConfig(cfg)
		typerEngine = typer.New(typer.Options{BaseDelay: cfg.BaseDelay, Humanise: cfg.Humanise})
		ovl.SetStealth(cfg.Stealth)
	})
	ovl.OnTypeReady(func() {
		if typing {
			_ = typerEngine.Type(answerBuffer)
			typing = false
		}
	})

	// Hotkeys — register off the main goroutine. golang.design/x/hotkey
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

func newClient(cfg config.Config) llm.Client {
	switch cfg.Provider {
	case config.ProviderCerebras:
		return llm.NewCerebras(cfg)
	default:
		return llm.NewGroq(cfg)
	}
}
