//go:build windows

package hotkey

import "testing"

func TestWindowsCombosUseControlAndExpectedKeys(t *testing.T) {
	cases := map[string]uint32{
		Capture: virtualKey('H'), Discussion: virtualKey('D'), AskQuestions: virtualKey('A'),
		Send: virtualKeyEnter, TypeAnswer: virtualKey('T'), ToggleListen: virtualKey('L'),
		PinToggle: virtualKey('P'), MoveLeft: virtualKeyLeft, MoveRight: virtualKeyRight,
		MoveUp: virtualKeyUp, MoveDown: virtualKeyDown,
	}
	for combo, expectedKey := range cases {
		modifiers, key, err := parseWindowsCombo(combo)
		if err != nil {
			t.Fatalf("parse %s: %v", combo, err)
		}
		if modifiers&modifierControl == 0 {
			t.Errorf("%s does not include Control", combo)
		}
		if key != expectedKey {
			t.Errorf("%s key = %#x, want %#x", combo, key, expectedKey)
		}
	}
}

func TestWindowsEscapeHasNoModifier(t *testing.T) {
	modifiers, key, err := parseWindowsCombo(Cancel)
	if err != nil {
		t.Fatal(err)
	}
	if modifiers != 0 || key != virtualKeyEscape {
		t.Fatalf("escape parsed as modifiers=%#x key=%#x", modifiers, key)
	}
}

func TestWindowsRejectsUnknownKey(t *testing.T) {
	if _, _, err := parseWindowsCombo("cmd+unknown"); err == nil {
		t.Fatal("unknown key was accepted")
	}
}

func virtualKey(letter byte) uint32 { return uint32(letter) }
