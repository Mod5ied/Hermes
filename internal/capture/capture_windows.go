//go:build windows

// Package capture provides allocation-bounded Win32 GDI screen capture.
package capture

import (
	"fmt"
	"image"
	"runtime"
	"sync"
	"syscall"
	"unsafe"
)

const (
	srccopy           = 0x00CC0020
	captureblt        = 0x40000000
	dibRGBColors      = 0
	pwRenderFull      = 0x00000002
	smXVirtualScreen  = 76
	smYVirtualScreen  = 77
	smCXVirtualScreen = 78
	smCYVirtualScreen = 79
)

var (
	user32Capture              = syscall.NewLazyDLL("user32.dll")
	gdi32Capture               = syscall.NewLazyDLL("gdi32.dll")
	getForegroundWindowCapture = user32Capture.NewProc("GetForegroundWindow")
	getWindowRectCapture       = user32Capture.NewProc("GetWindowRect")
	getWindowCapture           = user32Capture.NewProc("GetWindow")
	isWindowVisibleCapture     = user32Capture.NewProc("IsWindowVisible")
	getWindowProcessCapture    = user32Capture.NewProc("GetWindowThreadProcessId")
	getSystemMetricsCapture    = user32Capture.NewProc("GetSystemMetrics")
	getDCCapture               = user32Capture.NewProc("GetDC")
	releaseDCCapture           = user32Capture.NewProc("ReleaseDC")
	printWindowCapture         = user32Capture.NewProc("PrintWindow")
	enumWindowsCapture         = user32Capture.NewProc("EnumWindows")
	showWindowCapture          = user32Capture.NewProc("ShowWindow")
	createCompatibleDC         = gdi32Capture.NewProc("CreateCompatibleDC")
	deleteDCCapture            = gdi32Capture.NewProc("DeleteDC")
	createCompatibleBitmap     = gdi32Capture.NewProc("CreateCompatibleBitmap")
	selectObjectCapture        = gdi32Capture.NewProc("SelectObject")
	deleteObjectCapture        = gdi32Capture.NewProc("DeleteObject")
	bitBltCapture              = gdi32Capture.NewProc("BitBlt")
	getDIBitsCapture           = gdi32Capture.NewProc("GetDIBits")
	getCurrentProcessCapture   = syscall.NewLazyDLL("kernel32.dll").NewProc("GetCurrentProcessId")
	dwmFlushCapture            = syscall.NewLazyDLL("dwmapi.dll").NewProc("DwmFlush")
	enumOwnWindowCallback      = syscall.NewCallback(collectOwnWindow)
	frontCaptureMu             sync.Mutex
	ownWindowsDuringEnum       *ownWindowList
)

type Rect struct {
	X, Y, W, H int
}

func (r Rect) IsZero() bool { return r.W <= 0 || r.H <= 0 }

type winRect struct {
	Left, Top, Right, Bottom int32
}

type bitmapInfoHeader struct {
	Size            uint32
	Width           int32
	Height          int32
	Planes          uint16
	BitCount        uint16
	Compression     uint32
	SizeImage       uint32
	XPelsPerMeter   int32
	YPelsPerMeter   int32
	ColorsUsed      uint32
	ColorsImportant uint32
}

type bitmapInfo struct {
	Header bitmapInfoHeader
	Colors [1]uint32
}

func BackingScale() float64 { return 1 }

// Windows uses front-window capture for the hotkey path; region selection is
// deliberately omitted from the low-overhead port until a native selector is
// needed by the product surface.
func SelectRegion(seed Rect) (Rect, bool, error) {
	if seed.IsZero() {
		return Rect{}, false, fmt.Errorf("interactive region selection is not available on Windows")
	}
	return seed, true, nil
}

func CaptureRect(rect Rect) ([]byte, error) {
	if rect.IsZero() {
		return nil, fmt.Errorf("capture rect has zero area")
	}
	image, err := captureScreenRect(rect)
	if err != nil {
		return nil, err
	}
	return encodePNG(image)
}

func DecodePNG(data []byte) (image.Image, error) { return decodePNG(data) }

func CaptureImage(rect Rect) (image.Image, error) { return captureScreenRect(rect) }

func CaptureFrontWindow() (image.Image, error) {
	frontCaptureMu.Lock()
	defer frontCaptureMu.Unlock()

	handle, _, callErr := foregroundExternalWindow()
	if handle == 0 {
		return nil, fmt.Errorf("GetForegroundWindow failed: %w", callErr)
	}
	var nativeRect winRect
	ok, _, callErr := getWindowRectCapture.Call(handle, uintptr(unsafe.Pointer(&nativeRect)))
	if ok == 0 {
		return nil, fmt.Errorf("GetWindowRect failed: %w", callErr)
	}
	rect, err := clipToVirtualScreen(Rect{
		X: int(nativeRect.Left), Y: int(nativeRect.Top),
		W: int(nativeRect.Right - nativeRect.Left), H: int(nativeRect.Bottom - nativeRect.Top),
	})
	if err != nil {
		return nil, err
	}

	// Hide only this process's top-level windows for a compositor frame, then
	// copy the pixels actually shown to the user. This is the most reliable path
	// for Chromium and GPU-backed assessment pages and prevents Hermes itself
	// from contaminating the image sent to the vision model.
	restore := hideOwnWindows()
	img, screenErr := captureGDI(rect, 0)
	restore()
	if screenErr == nil {
		if validationErr := ValidateImageContent(img); validationErr == nil {
			return img, nil
		}
	}

	// PrintWindow is a fallback for windows temporarily covered by another
	// always-on-top application. Protected surfaces still fail validation and
	// are reported rather than forwarded as a hallucination-inducing black frame.
	if img, printErr := captureGDI(rect, handle); printErr == nil {
		if validationErr := ValidateImageContent(img); validationErr == nil {
			return img, nil
		}
	}
	if screenErr != nil {
		return nil, screenErr
	}
	return nil, fmt.Errorf("Windows front-window capture produced no usable pixels; the application may block capture")
}

type ownWindowList struct {
	process uint32
	count   int
	handles [16]uintptr
}

func hideOwnWindows() func() {
	process, _, _ := getCurrentProcessCapture.Call()
	windows := ownWindowList{process: uint32(process)}
	ownWindowsDuringEnum = &windows
	enumWindowsCapture.Call(enumOwnWindowCallback, 0)
	ownWindowsDuringEnum = nil
	for index := 0; index < windows.count; index++ {
		showWindowCapture.Call(windows.handles[index], 0) // SW_HIDE
	}
	dwmFlushCapture.Call()
	return func() {
		for index := 0; index < windows.count; index++ {
			showWindowCapture.Call(windows.handles[index], 4) // SW_SHOWNOACTIVATE
		}
		dwmFlushCapture.Call()
	}
}

func collectOwnWindow(window, context uintptr) uintptr {
	windows := ownWindowsDuringEnum
	if windows == nil {
		return 0
	}
	if windows.count >= len(windows.handles) {
		return 0
	}
	visible, _, _ := isWindowVisibleCapture.Call(window)
	if visible == 0 {
		return 1
	}
	var process uint32
	getWindowProcessCapture.Call(window, uintptr(unsafe.Pointer(&process)))
	if process == windows.process {
		windows.handles[windows.count] = window
		windows.count++
	}
	return 1
}

func foregroundExternalWindow() (uintptr, uintptr, error) {
	handle, _, callErr := getForegroundWindowCapture.Call()
	if handle == 0 {
		return 0, 0, callErr
	}
	process, _, _ := getCurrentProcessCapture.Call()
	for candidate := handle; candidate != 0; {
		var owner uint32
		getWindowProcessCapture.Call(candidate, uintptr(unsafe.Pointer(&owner)))
		visible, _, _ := isWindowVisibleCapture.Call(candidate)
		if uintptr(owner) != process && visible != 0 {
			return candidate, 0, nil
		}
		next, _, nextErr := getWindowCapture.Call(candidate, 2) // GW_HWNDNEXT
		if next == 0 {
			return 0, 0, nextErr
		}
		candidate = next
	}
	return 0, 0, callErr
}

func captureScreenRect(rect Rect) (image.Image, error) {
	clipped, err := clipToVirtualScreen(rect)
	if err != nil {
		return nil, err
	}
	return captureGDI(clipped, 0)
}

func captureGDI(rect Rect, window uintptr) (*image.NRGBA, error) {
	screenDC, _, callErr := getDCCapture.Call(0)
	if screenDC == 0 {
		return nil, fmt.Errorf("GetDC failed: %w", callErr)
	}
	defer releaseDCCapture.Call(0, screenDC)

	memoryDC, _, callErr := createCompatibleDC.Call(screenDC)
	if memoryDC == 0 {
		return nil, fmt.Errorf("CreateCompatibleDC failed: %w", callErr)
	}
	defer deleteDCCapture.Call(memoryDC)

	bitmap, _, callErr := createCompatibleBitmap.Call(screenDC, uintptr(rect.W), uintptr(rect.H))
	if bitmap == 0 {
		return nil, fmt.Errorf("CreateCompatibleBitmap failed: %w", callErr)
	}
	defer deleteObjectCapture.Call(bitmap)
	previous, _, _ := selectObjectCapture.Call(memoryDC, bitmap)
	if previous == 0 {
		return nil, fmt.Errorf("SelectObject failed")
	}
	defer selectObjectCapture.Call(memoryDC, previous)

	var copied uintptr
	if window != 0 {
		copied, _, callErr = printWindowCapture.Call(window, memoryDC, pwRenderFull)
	} else {
		copied, _, callErr = bitBltCapture.Call(
			memoryDC, 0, 0, uintptr(rect.W), uintptr(rect.H),
			screenDC, uintptr(int32(rect.X)), uintptr(int32(rect.Y)), srccopy|captureblt,
		)
	}
	if copied == 0 {
		return nil, fmt.Errorf("copy window pixels failed: %w", callErr)
	}

	pixels := make([]byte, rect.W*rect.H*4)
	info := bitmapInfo{Header: bitmapInfoHeader{
		Size: uint32(unsafe.Sizeof(bitmapInfoHeader{})), Width: int32(rect.W),
		Height: -int32(rect.H), Planes: 1, BitCount: 32,
	}}
	lines, _, callErr := getDIBitsCapture.Call(
		memoryDC, bitmap, 0, uintptr(rect.H), uintptr(unsafe.Pointer(&pixels[0])),
		uintptr(unsafe.Pointer(&info)), dibRGBColors,
	)
	if lines != uintptr(rect.H) {
		return nil, fmt.Errorf("GetDIBits returned %d of %d rows: %w", lines, rect.H, callErr)
	}
	for offset := 0; offset < len(pixels); offset += 4 {
		pixels[offset], pixels[offset+2] = pixels[offset+2], pixels[offset]
		pixels[offset+3] = 0xff
	}
	runtime.KeepAlive(info)
	return &image.NRGBA{Pix: pixels, Stride: rect.W * 4, Rect: image.Rect(0, 0, rect.W, rect.H)}, nil
}

func clipToVirtualScreen(rect Rect) (Rect, error) {
	x := systemMetric(smXVirtualScreen)
	y := systemMetric(smYVirtualScreen)
	w := systemMetric(smCXVirtualScreen)
	h := systemMetric(smCYVirtualScreen)
	left := maxInt(rect.X, x)
	top := maxInt(rect.Y, y)
	right := minInt(rect.X+rect.W, x+w)
	bottom := minInt(rect.Y+rect.H, y+h)
	clipped := Rect{X: left, Y: top, W: right - left, H: bottom - top}
	if clipped.IsZero() {
		return Rect{}, fmt.Errorf("capture rectangle is outside the virtual desktop")
	}
	return clipped, nil
}

func systemMetric(index int) int {
	value, _, _ := getSystemMetricsCapture.Call(uintptr(index))
	return int(int32(value))
}

func maxInt(a, b int) int {
	if a > b {
		return a
	}
	return b
}
func minInt(a, b int) int {
	if a < b {
		return a
	}
	return b
}

func init() {
	if unsafe.Sizeof(bitmapInfoHeader{}) != 40 {
		panic("Hermes Windows BITMAPINFOHEADER ABI layout mismatch")
	}
}
