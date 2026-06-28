// Package hotkey registers global system hotkeys.
package hotkey

import (
	"fmt"
	"strings"

	"golang.design/x/hotkey"
)

// Combo names supported by Register.
const (
	Capture      = "cmd+h"
	Send         = "cmd+enter"
	TypeAnswer   = "cmd+t"
	ToggleListen = "cmd+l"
	Cancel       = "esc"
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
	go func() {
		for {
			select {
			case <-quit:
				return
			case <-hk.Keydown():
				if fn != nil {
					fn()
				}
			}
		}
	}()

	unregister := func() {
		close(quit)
		hk.Unregister()
	}
	return unregister, nil
}

func parseCombo(combo string) ([]hotkey.Modifier, hotkey.Key, error) {
	parts := strings.Split(strings.ToLower(combo), "+")
	var mods []hotkey.Modifier
	var key hotkey.Key

	for _, p := range parts {
		switch p {
		case "cmd", "command", "meta":
			mods = append(mods, hotkey.ModCmd)
		case "shift":
			mods = append(mods, hotkey.ModShift)
		case "alt", "option":
			mods = append(mods, hotkey.ModOption)
		case "ctrl", "control":
			mods = append(mods, hotkey.ModCtrl)
		case "enter", "return":
			key = hotkey.KeyReturn
		case "esc", "escape":
			key = hotkey.KeyEscape
		case "h":
			key = hotkey.KeyH
		case "t":
			key = hotkey.KeyT
		case "l":
			key = hotkey.KeyL
		default:
			return nil, 0, fmt.Errorf("unknown combo part: %s", p)
		}
	}

	if key == 0 {
		return nil, 0, fmt.Errorf("no key in combo: %s", combo)
	}
	return mods, key, nil
}
