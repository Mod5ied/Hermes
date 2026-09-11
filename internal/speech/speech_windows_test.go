//go:build windows

package speech

import (
	"runtime"
	"testing"
	"unsafe"

	"github.com/stretchr/testify/assert"
)

func TestWindowsNativeStatsLayout(t *testing.T) {
	assert.Equal(t, uintptr(48), unsafe.Sizeof(windowsNativeStats{}))
}

func TestWindowsThreadCountIsBounded(t *testing.T) {
	t.Setenv("HERMES_STT_THREADS", "99")
	want := runtime.NumCPU()
	if want > 3 {
		want = 3
	}
	assert.Equal(t, want, windowsThreadCount())
}

func TestWindowsExplicitLocaleDoesNotQuerySystem(t *testing.T) {
	assert.Equal(t, "pt", windowsWhisperLanguage("pt-BR"))
}
