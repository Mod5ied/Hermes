//go:build windows

package speech

import (
	"fmt"
	"log"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
	"unsafe"
)

const (
	windowsSTTDLL             = "hermes-stt.dll"
	windowsPollInterval       = 25 * time.Millisecond
	windowsResultBytes        = 64 * 1024
	windowsLocaleNameCapacity = 85
)

var getUserDefaultLocaleName = syscall.NewLazyDLL("kernel32.dll").NewProc("GetUserDefaultLocaleName")

type windowsTranscriber struct {
	opMu      sync.Mutex
	mu        sync.Mutex
	locale    string
	api       *windowsSTTAPI
	engine    uintptr
	callback  func(Result)
	running   bool
	stopPoll  chan struct{}
	pollDone  chan struct{}
	resultBuf []byte
}

type windowsSTTAPI struct {
	dll       *syscall.DLL
	abi       *syscall.Proc
	create    *syscall.Proc
	start     *syscall.Proc
	read      *syscall.Proc
	stop      *syscall.Proc
	reset     *syscall.Proc
	getStats  *syscall.Proc
	destroy   *syscall.Proc
	lastError *syscall.Proc
}

type windowsSTTConfig struct {
	dllPath   string
	modelPath string
	language  string
	threads   int
}

type windowsNativeStats struct {
	ABIVersion           uint32
	StructSize           uint32
	CapturedSamples      uint64
	SpeechSamples        uint64
	DecodeCount          uint64
	DecodeMilliseconds   uint64
	DroppedJobs          uint32
	AudioDiscontinuities uint32
}

func newTranscriber(locale string) Transcriber {
	t := &windowsTranscriber{
		locale:    locale,
		resultBuf: make([]byte, windowsResultBytes),
	}
	runtime.SetFinalizer(t, (*windowsTranscriber).close)
	return t
}

func analyzerAvailable() bool { return false }

func (t *windowsTranscriber) Start(onResult func(Result)) error {
	if onResult == nil {
		return fmt.Errorf("no callback provided")
	}

	t.opMu.Lock()
	defer t.opMu.Unlock()
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.running {
		t.callback = onResult
		return nil
	}
	if err := t.ensureEngineLocked(); err != nil {
		return err
	}
	if code := callCode(t.api.start, t.engine); code != 0 {
		return t.nativeErrorLocked("start WASAPI loopback capture", code)
	}

	t.callback = onResult
	t.running = true
	t.stopPoll = make(chan struct{})
	t.pollDone = make(chan struct{})
	go t.poll(t.stopPoll, t.pollDone)
	return nil
}

func (t *windowsTranscriber) Stop() error {
	t.opMu.Lock()
	defer t.opMu.Unlock()
	t.mu.Lock()
	if !t.running {
		t.mu.Unlock()
		return nil
	}
	stopPoll := t.stopPoll
	pollDone := t.pollDone
	t.running = false
	close(stopPoll)
	t.mu.Unlock()

	<-pollDone
	code := callCode(t.api.stop, t.engine)
	if code != 0 {
		t.mu.Lock()
		err := t.nativeErrorLocked("stop speech engine", code)
		t.mu.Unlock()
		return err
	}
	t.drainResults()
	t.logStats()
	return nil
}

func (t *windowsTranscriber) Reset() error {
	t.opMu.Lock()
	defer t.opMu.Unlock()
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.engine == 0 {
		return nil
	}
	if code := callCode(t.api.reset, t.engine); code != 0 {
		return t.nativeErrorLocked("reset speech engine", code)
	}
	return nil
}

func (t *windowsTranscriber) ensureEngineLocked() error {
	if t.engine != 0 {
		return nil
	}
	cfg, err := resolveWindowsSTTConfig(t.locale)
	if err != nil {
		return err
	}
	api, err := loadWindowsSTTAPI(cfg.dllPath)
	if err != nil {
		return err
	}
	model, err := syscall.UTF16PtrFromString(cfg.modelPath)
	if err != nil {
		api.dll.Release()
		return fmt.Errorf("invalid whisper model path: %w", err)
	}
	language, err := syscall.UTF16PtrFromString(cfg.language)
	if err != nil {
		api.dll.Release()
		return fmt.Errorf("invalid speech locale: %w", err)
	}

	var engine uintptr
	result, _, _ := api.create.Call(
		uintptr(unsafe.Pointer(model)),
		uintptr(unsafe.Pointer(language)),
		uintptr(cfg.threads),
		uintptr(unsafe.Pointer(&engine)),
	)
	runtime.KeepAlive(model)
	runtime.KeepAlive(language)
	code := int32(result)
	if code != 0 || engine == 0 {
		detail := api.errorText(0)
		api.dll.Release()
		return formatNativeError("load whisper.cpp model", code, detail)
	}
	t.api = api
	t.engine = engine
	return nil
}

func (t *windowsTranscriber) poll(stop <-chan struct{}, done chan<- struct{}) {
	defer close(done)
	ticker := time.NewTicker(windowsPollInterval)
	defer ticker.Stop()
	buf := t.resultBuf

	for {
		select {
		case <-stop:
			return
		case <-ticker.C:
			for range 8 {
				read, final, err := t.readResult(buf)
				if err != nil {
					log.Printf("windows speech: %v", err)
					break
				}
				if read == 0 {
					break
				}
				t.deliver(Result{Text: string(buf[:read]), Final: final})
			}
		}
	}
}

func (t *windowsTranscriber) readResult(buf []byte) (int, bool, error) {
	var final int32
	result, _, _ := t.api.read.Call(
		t.engine,
		uintptr(unsafe.Pointer(&buf[0])),
		uintptr(len(buf)),
		uintptr(unsafe.Pointer(&final)),
	)
	read := int32(result)
	if read < 0 {
		return 0, false, formatNativeError("read transcription", read, t.api.errorText(t.engine))
	}
	return int(read), final != 0, nil
}

func (t *windowsTranscriber) deliver(result Result) {
	t.mu.Lock()
	callback := t.callback
	t.mu.Unlock()
	if callback != nil {
		callback(result)
	}
}

func (t *windowsTranscriber) drainResults() {
	buf := t.resultBuf
	for range 16 {
		read, final, err := t.readResult(buf)
		if err != nil || read == 0 {
			return
		}
		t.deliver(Result{Text: string(buf[:read]), Final: final})
	}
}

func (t *windowsTranscriber) logStats() {
	stats := windowsNativeStats{StructSize: uint32(unsafe.Sizeof(windowsNativeStats{}))}
	code := callCode(t.api.getStats, t.engine, uintptr(unsafe.Pointer(&stats)))
	if code != 0 {
		return
	}
	log.Printf(
		"windows speech: captured=%.1fs speech=%.1fs decodes=%d decode_wall=%.2fs dropped=%d discontinuities=%d",
		float64(stats.CapturedSamples)/16000.0,
		float64(stats.SpeechSamples)/16000.0,
		stats.DecodeCount,
		float64(stats.DecodeMilliseconds)/1000.0,
		stats.DroppedJobs,
		stats.AudioDiscontinuities,
	)
}

func (t *windowsTranscriber) nativeErrorLocked(operation string, code int32) error {
	return formatNativeError(operation, code, t.api.errorText(t.engine))
}

func (t *windowsTranscriber) close() {
	_ = t.Stop()
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.engine != 0 {
		callCode(t.api.destroy, t.engine)
		t.engine = 0
	}
	if t.api != nil && t.api.dll != nil {
		_ = t.api.dll.Release()
		t.api = nil
	}
}

func resolveWindowsSTTConfig(locale string) (windowsSTTConfig, error) {
	executable, err := os.Executable()
	if err != nil {
		return windowsSTTConfig{}, fmt.Errorf("locate Hermes executable: %w", err)
	}
	root := filepath.Dir(executable)
	language := windowsWhisperLanguage(locale)
	dllPath := pathFromEnvironment("HERMES_STT_DLL", filepath.Join(root, windowsSTTDLL))
	modelPreset := "base-q5_1"
	if language == "en" {
		modelPreset = "base.en-q5_1"
	}
	modelName := "ggml-" + modelPreset + ".bin"
	modelPath := pathFromEnvironment("HERMES_STT_MODEL", filepath.Join(root, "models", modelName))
	if _, err := os.Stat(modelPath); err != nil {
		return windowsSTTConfig{}, fmt.Errorf("Whisper model unavailable at %s; run scripts\\setup-windows-stt.ps1 -Model %s or set HERMES_STT_MODEL", modelPath, modelPreset)
	}
	return windowsSTTConfig{
		dllPath:   dllPath,
		modelPath: modelPath,
		language:  language,
		threads:   windowsThreadCount(),
	}, nil
}

func windowsWhisperLanguage(locale string) string {
	if strings.TrimSpace(locale) != "" {
		return whisperLanguage(locale)
	}
	buffer := make([]uint16, windowsLocaleNameCapacity)
	result, _, _ := getUserDefaultLocaleName.Call(
		uintptr(unsafe.Pointer(&buffer[0])),
		uintptr(len(buffer)),
	)
	if result == 0 {
		return "en"
	}
	return whisperLanguage(syscall.UTF16ToString(buffer))
}

func pathFromEnvironment(name, fallback string) string {
	if value := strings.TrimSpace(os.Getenv(name)); value != "" {
		if absolute, err := filepath.Abs(value); err == nil {
			return absolute
		}
		return value
	}
	return fallback
}

func windowsThreadCount() int {
	threads := 2
	if value, err := strconv.Atoi(strings.TrimSpace(os.Getenv("HERMES_STT_THREADS"))); err == nil && value > 0 {
		threads = value
	}
	logical := runtime.NumCPU()
	if logical < 1 {
		logical = 1
	}
	if threads > logical {
		threads = logical
	}
	if threads > 3 {
		threads = 3
	}
	return threads
}

func loadWindowsSTTAPI(path string) (*windowsSTTAPI, error) {
	dll, err := syscall.LoadDLL(path)
	if err != nil {
		return nil, fmt.Errorf("load %s: %w; run scripts\\build-windows-stt.ps1 first", path, err)
	}
	api := &windowsSTTAPI{dll: dll}
	procedures := []struct {
		name string
		dest **syscall.Proc
	}{
		{"hermes_stt_abi_version", &api.abi},
		{"hermes_stt_create", &api.create},
		{"hermes_stt_start", &api.start},
		{"hermes_stt_read", &api.read},
		{"hermes_stt_stop", &api.stop},
		{"hermes_stt_reset", &api.reset},
		{"hermes_stt_get_stats", &api.getStats},
		{"hermes_stt_destroy", &api.destroy},
		{"hermes_stt_last_error", &api.lastError},
	}
	for _, procedure := range procedures {
		proc, findErr := dll.FindProc(procedure.name)
		if findErr != nil {
			dll.Release()
			return nil, fmt.Errorf("%s is missing %s: %w", path, procedure.name, findErr)
		}
		*procedure.dest = proc
	}
	version, _, _ := api.abi.Call()
	if uint32(version) != 1 {
		dll.Release()
		return nil, fmt.Errorf("%s uses unsupported STT ABI %d (expected 1)", path, uint32(version))
	}
	return api, nil
}

func (api *windowsSTTAPI) errorText(engine uintptr) string {
	buffer := make([]uint16, 1024)
	api.lastError.Call(engine, uintptr(unsafe.Pointer(&buffer[0])), uintptr(len(buffer)))
	return strings.TrimSpace(syscall.UTF16ToString(buffer))
}

func callCode(proc *syscall.Proc, args ...uintptr) int32 {
	result, _, _ := proc.Call(args...)
	return int32(result)
}

func formatNativeError(operation string, code int32, detail string) error {
	if detail == "" {
		return fmt.Errorf("%s failed (code %d)", operation, code)
	}
	return fmt.Errorf("%s failed (code %d): %s", operation, code, detail)
}
