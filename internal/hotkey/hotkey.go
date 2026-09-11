//go:build !windows

// Package hotkey registers global system hotkeys.
package hotkey

import (
	"fmt"
	"strings"

	"golang.design/x/hotkey"
)

// Combo names supported by Register.
const (
	Capture         = "cmd+h"
	ReselectCapture = "cmd+shift+h"
	Discussion      = "cmd+d"
	AskQuestions    = "cmd+a"
	Send            = "cmd+enter"
	TypeAnswer      = "cmd+t"
	ToggleListen    = "cmd+l"
	PinToggle       = "cmd+p"
	Cancel          = "esc"
	MoveLeft        = "cmd+left"
	MoveRight       = "cmd+right"
	MoveUp          = "cmd+up"
	MoveDown        = "cmd+down"
)

// Register registers a global hotkey for the given combo and calls fn when pressed.
// Returns an unregister function. The hotkey loop must run on the main thread.
func Register(combo string, fn func()) (func(), error) {
	mods, key, err := parseCombo(combo)
	if err != nil {
		return nil, err
	}

	hk := hotkey.New(mods, key)
	if err := hk.Register(); err != nil {
		return nil, fmt.Errorf("register hotkey %s: %w", combo, err)
	}

	quit := make(chan struct{})
	go listen(hk, quit, fn)

	unregister := func() {
		close(quit)
		hk.Unregister()
	}
	return unregister, nil
}

func listen(hk *hotkey.Hotkey, quit <-chan struct{}, fn func()) {
	for {
		select {
		case <-quit:
			return
		case <-hk.Keydown():
			call(fn)
		}
	}
}

func call(fn func()) {
	if fn != nil {
		fn()
	}
}

var modifierNames = map[string]hotkey.Modifier{
	"cmd": hotkey.ModCmd, "command": hotkey.ModCmd, "meta": hotkey.ModCmd,
	"shift": hotkey.ModShift,
	"alt":   hotkey.ModOption, "option": hotkey.ModOption,
	"ctrl": hotkey.ModCtrl, "control": hotkey.ModCtrl,
}

var keyNames = map[string]hotkey.Key{
	"enter": hotkey.KeyReturn, "return": hotkey.KeyReturn,
	"esc": hotkey.KeyEscape, "escape": hotkey.KeyEscape,
	"a": hotkey.KeyA, "d": hotkey.KeyD, "h": hotkey.KeyH, "t": hotkey.KeyT,
	"l": hotkey.KeyL, "p": hotkey.KeyP,
	"left": hotkey.KeyLeft, "right": hotkey.KeyRight,
	"up": hotkey.KeyUp, "down": hotkey.KeyDown,
}

func parseCombo(combo string) ([]hotkey.Modifier, hotkey.Key, error) {
	parts := strings.Split(strings.ToLower(combo), "+")
	var mods []hotkey.Modifier
	var key hotkey.Key
	foundKey := false

	for _, p := range parts {
		if mod, ok := modifierNames[p]; ok {
			mods = append(mods, mod)
			continue
		}
		var ok bool
		key, ok = keyNames[p]
		if !ok {
			return nil, 0, fmt.Errorf("unknown combo part: %s", p)
		}
		foundKey = true
	}

	if !foundKey {
		return nil, 0, fmt.Errorf("no key in combo: %s", combo)
	}
	return mods, key, nil
}
