// Hermes: capture, answer, type.
package main

import (
	"context"
	"log"
	"time"

	"golang.design/x/mainthread"

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
	mainthread.Init(run)
}

func run() {
	cfg, err := config.Load()
	if err != nil {
		log.Fatalf("load config: %v", err)
	}

	client := llm.NewGroq(cfg)
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
		region := cfg.Region
		if region == nil {
			r, ok, err := capture.SelectRegion(capture.Rect{})
			if err != nil {
				log.Printf("select region: %v", err)
				return
			}
			if !ok {
				return
			}
			region = &config.Rect{X: r.X, Y: r.Y, W: r.W, H: r.H}
			cfg.Region = region
			_ = config.Save(cfg)
		}

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
		cancelAll()
		thread.Clear()
		tray.Clear()
		answerBuffer = ""
		ovl.SetTrayCount(0)
		ovl.SetAnswerCount(0)
	})
	ovl.OnListenToggle(func(on bool) {
		listening = on
		doListenToggle(on)
	})
	ovl.OnSettings(func() {
		overlay.ShowSettings(cfg)
	})
	ovl.OnSettingsSaved(func(apiKey, model string, stealth, humanise bool, delay time.Duration, resumeProfile, speechLocale string) {
		cfg.APIKey = apiKey
		cfg.Model = model
		cfg.Stealth = stealth
		cfg.Humanise = humanise
		cfg.BaseDelay = delay
		cfg.ResumeProfile = resumeProfile
		cfg.SpeechLocale = speechLocale
		if err := config.Save(cfg); err != nil {
			log.Printf("save settings: %v", err)
		}
		client = llm.NewGroq(cfg)
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

	// Hotkeys — must be registered on the main thread.
	mainthread.Call(func() {
		register := func(combo string, fn func()) {
			if _, err := hotkey.Register(combo, fn); err != nil {
				log.Printf("hotkey disabled (%s): %v", combo, err)
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
	})

	// Rate-limit indicator ticker.
	go func() {
		ticker := time.NewTicker(500 * time.Millisecond)
		defer ticker.Stop()
		for range ticker.C {
			updateIndicator()
		}
	}()

	ovl.Show()
	overlay.Run()
}
