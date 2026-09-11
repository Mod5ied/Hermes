//go:build windows

// Package hotkey registers all Windows shortcuts on one Win32 message thread.
package hotkey

import (
	"fmt"
	"runtime"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"unsafe"
)

const (
	Capture      = "cmd+h"
	Discussion   = "cmd+d"
	AskQuestions = "cmd+a"
	Send         = "cmd+enter"
	TypeAnswer   = "cmd+t"
	ToggleListen = "cmd+l"
	PinToggle    = "cmd+p"
	Cancel       = "esc"
	MoveLeft     = "cmd+left"
	MoveRight    = "cmd+right"
	MoveUp       = "cmd+up"
	MoveDown     = "cmd+down"

	wmHotkey         = 0x0312
	wmAppCommand     = 0x8001
	pmNoRemove       = 0x0000
	modifierAlt      = 0x0001
	modifierControl  = 0x0002
	modifierShift    = 0x0004
	modifierNoRepeat = 0x4000

	virtualKeyEnter  = 0x0D
	virtualKeyEscape = 0x1B
	virtualKeyLeft   = 0x25
	virtualKeyUp     = 0x26
	virtualKeyRight  = 0x27
	virtualKeyDown   = 0x28
)

var (
	user32Hotkey            = syscall.NewLazyDLL("user32.dll")
	kernel32Hotkey          = syscall.NewLazyDLL("kernel32.dll")
	registerHotKeyWindows   = user32Hotkey.NewProc("RegisterHotKey")
	unregisterHotKeyWindows = user32Hotkey.NewProc("UnregisterHotKey")
	getMessageWindows       = user32Hotkey.NewProc("GetMessageW")
	peekMessageWindows      = user32Hotkey.NewProc("PeekMessageW")
	postThreadMessage       = user32Hotkey.NewProc("PostThreadMessageW")
	getCurrentThreadID      = kernel32Hotkey.NewProc("GetCurrentThreadId")

	managerOnce sync.Once
	manager     *windowsHotkeyManager
	nextID      atomic.Int32
)

type point struct{ X, Y int32 }

type windowMessage struct {
	Window  uintptr
	Message uint32
	Padding uint32
	WParam  uintptr
	LParam  uintptr
	Time    uint32
	Point   point
	Private uint32
}

type hotkeyCommand struct {
	register  bool
	id        int32
	modifiers uint32
	key       uint32
	handler   func()
	result    chan error
}

type windowsHotkeyManager struct {
	threadID uint32
	commands chan hotkeyCommand
	ready    chan struct{}
	handlers map[int32]func()
}

func Register(combo string, handler func()) (func(), error) {
	modifiers, key, err := parseWindowsCombo(combo)
	if err != nil {
		return nil, err
	}
	managerOnce.Do(startHotkeyManager)
	<-manager.ready

	id := nextID.Add(1)
	command := hotkeyCommand{
		register: true, id: id, modifiers: modifiers, key: key,
		handler: handler, result: make(chan error, 1),
	}
	manager.commands <- command
	wakeHotkeyManager()
	if err := <-command.result; err != nil {
		return nil, fmt.Errorf("register hotkey %s: %w", combo, err)
	}

	var once sync.Once
	return func() {
		once.Do(func() {
			command := hotkeyCommand{register: false, id: id, result: make(chan error, 1)}
			manager.commands <- command
			wakeHotkeyManager()
			<-command.result
		})
	}, nil
}

func startHotkeyManager() {
	manager = &windowsHotkeyManager{
		commands: make(chan hotkeyCommand, 32),
		ready:    make(chan struct{}),
		handlers: make(map[int32]func()),
	}
	go manager.run()
}

func (m *windowsHotkeyManager) run() {
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()
	id, _, _ := getCurrentThreadID.Call()
	m.threadID = uint32(id)
	var message windowMessage
	// Force creation of this thread's message queue before allowing posts.
	peekMessageWindows.Call(uintptr(unsafe.Pointer(&message)), 0, 0, 0, pmNoRemove)
	close(m.ready)

	for {
		result, _, _ := getMessageWindows.Call(uintptr(unsafe.Pointer(&message)), 0, 0, 0)
		if int32(result) <= 0 {
			return
		}
		switch message.Message {
		case wmAppCommand:
			m.applyCommands()
		case wmHotkey:
			if handler := m.handlers[int32(message.WParam)]; handler != nil {
				go handler()
			}
		}
	}
}

func (m *windowsHotkeyManager) applyCommands() {
	for {
		select {
		case command := <-m.commands:
			if command.register {
				ok, _, callErr := registerHotKeyWindows.Call(
					0, uintptr(command.id), uintptr(command.modifiers|modifierNoRepeat), uintptr(command.key),
				)
				if ok == 0 {
					command.result <- callErr
					continue
				}
				m.handlers[command.id] = command.handler
				command.result <- nil
				continue
			}
			unregisterHotKeyWindows.Call(0, uintptr(command.id))
			delete(m.handlers, command.id)
			command.result <- nil
		default:
			return
		}
	}
}

func wakeHotkeyManager() {
	postThreadMessage.Call(uintptr(manager.threadID), wmAppCommand, 0, 0)
}

func parseWindowsCombo(combo string) (uint32, uint32, error) {
	var modifiers uint32
	var key uint32
	for _, part := range strings.Split(strings.ToLower(combo), "+") {
		switch part {
		case "cmd", "command", "meta", "ctrl", "control":
			modifiers |= modifierControl
		case "shift":
			modifiers |= modifierShift
		case "alt", "option":
			modifiers |= modifierAlt
		case "enter", "return":
			key = virtualKeyEnter
		case "esc", "escape":
			key = virtualKeyEscape
		case "left":
			key = virtualKeyLeft
		case "right":
			key = virtualKeyRight
		case "up":
			key = virtualKeyUp
		case "down":
			key = virtualKeyDown
		default:
			if len(part) == 1 && part[0] >= 'a' && part[0] <= 'z' {
				key = uint32(part[0] - 'a' + 'A')
				continue
			}
			return 0, 0, fmt.Errorf("unknown combo part: %s", part)
		}
	}
	if key == 0 {
		return 0, 0, fmt.Errorf("no key in combo: %s", combo)
	}
	return modifiers, key, nil
}

func init() {
	if unsafe.Sizeof(windowMessage{}) != 48 {
		panic("Hermes Windows MSG ABI layout mismatch")
	}
}
