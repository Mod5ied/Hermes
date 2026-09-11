package main

import (
	"encoding/binary"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"runtime"
	"strings"
	"sync"
	"time"

	"github.com/hermes/hermes/internal/config"
	"github.com/hermes/hermes/internal/overlay"
)

const (
	nativeHostName       = "com.hermes.app"
	maxNativeInputBytes  = 64 << 20
	maxNativeOutputBytes = 1 << 20
)

type nativeCommand struct {
	ID       int                      `json:"id"`
	Type     string                   `json:"type"`
	Command  string                   `json:"command,omitempty"`
	Enabled  bool                     `json:"enabled"`
	Settings *nativeCompanionSettings `json:"settings,omitempty"`
}

type nativeCompanionSettings struct {
	Provider       string `json:"provider"`
	Model          string `json:"model"`
	APIKey         string `json:"apiKey"`
	Humanise       bool   `json:"humanise"`
	BaseDelayMS    int    `json:"baseDelayMs"`
	OverlayOpacity int    `json:"overlayOpacity"`
	AnswerFontSize int    `json:"answerFontSize"`
	ResumeProfile  string `json:"resumeProfile"`
	SpeechLocale   string `json:"speechLocale"`
}

type nativeWriter struct {
	mu sync.Mutex
	w  io.Writer
}

func isNativeMessagingInvocation(args []string) bool {
	for _, arg := range args {
		if arg == "--native-messaging" || arg == "hermes@project-hermes.dev" ||
			strings.HasPrefix(arg, "chrome-extension://") || strings.HasPrefix(arg, "moz-extension://") ||
			strings.HasSuffix(arg, "/com.hermes.app.json") {
			return true
		}
	}
	return false
}

func runNativeMessaging() {
	app := initializeApplicationWithPassRefresh(false)
	app.overlay.Hide()
	writer := &nativeWriter{w: os.Stdout}
	app.stealthChanged = func(enabled bool) {
		_ = writer.write(map[string]any{"type": "STEALTH_CHANGED", "enabled": enabled})
	}
	go serveNativeMessaging(app, os.Stdin, writer)
	overlay.Run()
}

func serveNativeMessaging(app *application, input io.Reader, writer *nativeWriter) {
	visible := false
	_ = writer.write(map[string]any{
		"type":       "READY",
		"host":       nativeHostName,
		"platform":   runtime.GOOS,
		"protection": "best_effort",
	})
	defer func() {
		app.overlay.Hide()
		overlay.Quit()
	}()

	for {
		var command nativeCommand
		if err := readNativeMessage(input, &command); err != nil {
			if err != io.EOF && err != io.ErrUnexpectedEOF {
				_ = writer.write(map[string]any{"type": "ERROR", "error": err.Error()})
			}
			return
		}

		switch command.Type {
		case "PING":
			_ = writer.respond(command.ID, true, "", visible)
		case "SET_STEALTH":
			if command.Enabled {
				app.applyCompanionSettings(command.Settings)
				app.cfg.Stealth = true
				app.overlay.SetStealth(true)
				app.overlay.Show()
				visible = true
			} else {
				app.cfg.Stealth = false
				_ = config.Save(app.cfg)
				app.overlay.SetStealth(false)
				app.overlay.Hide()
				visible = false
			}
			_ = writer.respond(command.ID, true, "", visible)
		case "TOGGLE":
			app.applyCompanionSettings(command.Settings)
			app.cfg.Stealth = true
			app.overlay.SetStealth(true)
			visible = !visible
			if visible {
				app.overlay.Show()
			} else {
				app.overlay.Hide()
			}
			_ = writer.respond(command.ID, true, "", visible)
		case "COMMAND":
			app.applyCompanionSettings(command.Settings)
			switch command.Command {
			case "capture-region":
				app.doCapture()
			case "toggle-listen":
				app.listenToggle(!app.listening)
			case "type-answer":
				app.doType()
			default:
				_ = writer.respond(command.ID, false, "Unsupported Hermes command", visible)
				continue
			}
			_ = writer.respond(command.ID, true, "", visible)
		default:
			_ = writer.respond(command.ID, false, "Unsupported native command", visible)
		}
	}
}

func (a *application) applyCompanionSettings(settings *nativeCompanionSettings) {
	if settings == nil {
		return
	}
	delay := time.Duration(settings.BaseDelayMS) * time.Millisecond
	a.applySettings(settings.APIKey, settings.Provider, settings.Model, true, settings.Humanise, delay, settings.ResumeProfile, settings.SpeechLocale)
	if settings.OverlayOpacity > 0 {
		a.cfg.OverlayOpacity = settings.OverlayOpacity
	}
	if settings.AnswerFontSize > 0 {
		a.cfg.AnswerFontSize = settings.AnswerFontSize
	}
	config.ApplyProviderDefaults(&a.cfg)
	_ = config.Save(a.cfg)
	a.reconfigure()
	a.applyDisplaySettings()
}

func readNativeMessage(reader io.Reader, target any) error {
	var header [4]byte
	if _, err := io.ReadFull(reader, header[:]); err != nil {
		return err
	}
	size := binary.LittleEndian.Uint32(header[:])
	if size == 0 || size > maxNativeInputBytes {
		return fmt.Errorf("invalid native message size: %d", size)
	}
	payload := make([]byte, size)
	if _, err := io.ReadFull(reader, payload); err != nil {
		return err
	}
	if err := json.Unmarshal(payload, target); err != nil {
		return fmt.Errorf("decode native message: %w", err)
	}
	return nil
}

func (w *nativeWriter) respond(id int, ok bool, errorMessage string, visible bool) error {
	return w.write(map[string]any{"type": "RESPONSE", "id": id, "ok": ok, "error": errorMessage, "visible": visible})
}

func (w *nativeWriter) write(message any) error {
	payload, err := json.Marshal(message)
	if err != nil {
		return err
	}
	if len(payload) > maxNativeOutputBytes {
		return fmt.Errorf("native response exceeds %d bytes", maxNativeOutputBytes)
	}
	var header [4]byte
	binary.LittleEndian.PutUint32(header[:], uint32(len(payload)))
	w.mu.Lock()
	defer w.mu.Unlock()
	if _, err := w.w.Write(header[:]); err != nil {
		return err
	}
	_, err = w.w.Write(payload)
	return err
}
