// Package capture handles screen region selection and in-memory capture.
package capture

// #cgo CFLAGS: -x objective-c
// #cgo LDFLAGS: -framework Cocoa -framework ScreenCaptureKit -framework CoreGraphics -framework CoreFoundation
/*
#include <stdbool.h>
#include <stdlib.h>

// hermes_capture_rect captures the given rect from the screen in-process.
// On success it sets *outData to a malloc'd PNG buffer and *outLen to its size.
// Caller must free *outData with free().
int hermes_capture_rect(int x, int y, int w, int h, void **outData, size_t *outLen);

// hermes_select_region shows a full-screen selection overlay and returns the
// selected rectangle in screen points (bottom-left origin, AppKit window space).
// If the user cancels, width and height are zero.
void hermes_select_region(int seedX, int seedY, int seedW, int seedH,
                          int *outX, int *outY, int *outW, int *outH);

// hermes_backing_scale returns the backing scale factor of the main screen.
double hermes_backing_scale(void);
*/
import "C"
import (
	"bytes"
	"fmt"
	"image"
	"image/png"
	"unsafe"
)

// Rect is a screen region in display pixels.
type Rect struct {
	X, Y, W, H int
}

// IsZero reports whether the rect has no area.
func (r Rect) IsZero() bool {
	return r.W <= 0 || r.H <= 0
}

// BackingScale returns the main display's backing scale factor.
func BackingScale() float64 {
	return float64(C.hermes_backing_scale())
}

// SelectRegion shows the selection overlay seeded with the given rect and
// returns the selected region in display pixels. If the user cancels, ok is false.
func SelectRegion(seed Rect) (Rect, bool, error) {
	var cx, cy, cw, ch C.int
	// The selector works in AppKit window points (bottom-left origin).
	// The stored seed is in display pixels, so convert it before passing it in.
	scale := BackingScale()
	C.hermes_select_region(
		C.int(float64(seed.X)/scale), C.int(float64(seed.Y)/scale),
		C.int(float64(seed.W)/scale), C.int(float64(seed.H)/scale),
		&cx, &cy, &cw, &ch,
	)
	w := int(cw)
	h := int(ch)
	if w <= 0 || h <= 0 {
		return Rect{}, false, nil
	}

	// Convert points to pixels for storage and capture.
	r := Rect{
		X: int(float64(int(cx)) * scale),
		Y: int(float64(int(cy)) * scale),
		W: int(float64(w) * scale),
		H: int(float64(h) * scale),
	}
	return r, true, nil
}

// CaptureRect captures the given rect in-process to a PNG-encoded byte slice.
// The caller is responsible for decoding or forwarding the bytes.
func CaptureRect(r Rect) ([]byte, error) {
	if r.IsZero() {
		return nil, fmt.Errorf("capture rect has zero area")
	}

	var outData unsafe.Pointer
	var outLen C.size_t

	ret := C.hermes_capture_rect(
		C.int(r.X), C.int(r.Y), C.int(r.W), C.int(r.H),
		&outData, &outLen,
	)
	if outData != nil {
		defer C.free(outData)
	}
	if ret != 0 {
		return nil, fmt.Errorf("screen capture failed (code %d)", int(ret))
	}
	if outLen == 0 {
		return nil, fmt.Errorf("screen capture returned empty buffer")
	}

	buf := C.GoBytes(outData, C.int(outLen))
	return buf, nil
}

// DecodePNG decodes a PNG byte slice to an image.Image.
func DecodePNG(data []byte) (image.Image, error) {
	return png.Decode(bytes.NewReader(data))
}

// CaptureImage captures and decodes a rect into an image.Image.
func CaptureImage(r Rect) (image.Image, error) {
	data, err := CaptureRect(r)
	if err != nil {
		return nil, err
	}
	return DecodePNG(data)
}
