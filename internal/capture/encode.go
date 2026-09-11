package capture

import (
	"bytes"
	"encoding/base64"
	"fmt"
	"image"
	"image/jpeg"
	"image/png"
	"math"

	"golang.org/x/image/draw"
)

const maxBase64Bytes = 4 * 1024 * 1024 // 4 MB

// ValidateImageContent rejects frames that ScreenCaptureKit technically
// returned successfully but that contain no useful visual information. macOS
// can produce such frames for protected or otherwise unavailable windows.
func ValidateImageContent(img image.Image) error {
	bounds, err := contentBounds(img)
	if err != nil {
		return err
	}
	stats := sampleImage(img, bounds)
	if stats.isBlack() {
		return fmt.Errorf("captured window is black; it may block screen capture")
	}
	if stats.isBlank() {
		return fmt.Errorf("captured window is visually blank")
	}
	return nil
}

func contentBounds(img image.Image) (image.Rectangle, error) {
	if img == nil {
		return image.Rectangle{}, fmt.Errorf("screen capture returned no image")
	}
	bounds := img.Bounds()
	if bounds.Dx() <= 0 || bounds.Dy() <= 0 {
		return image.Rectangle{}, fmt.Errorf("screen capture returned an empty image")
	}
	return bounds, nil
}

type imageStats struct {
	samples, dark    int64
	mean, m2         float64
	minLuma, maxLuma float64
}

func sampleImage(img image.Image, bounds image.Rectangle) imageStats {
	stats := imageStats{minLuma: 255}
	stride := sampleStride(bounds)
	for y := bounds.Min.Y; y < bounds.Max.Y; y += stride {
		for x := bounds.Min.X; x < bounds.Max.X; x += stride {
			r, g, b, _ := img.At(x, y).RGBA()
			luma := (0.2126*float64(r) + 0.7152*float64(g) + 0.0722*float64(b)) / 257.0
			stats.add(luma)
		}
	}
	return stats
}

func sampleStride(bounds image.Rectangle) int {
	stride := int(math.Sqrt(float64(bounds.Dx()*bounds.Dy()) / 65536.0))
	if stride < 1 {
		return 1
	}
	return stride
}

func (s *imageStats) add(luma float64) {
	s.samples++
	if luma <= 8 {
		s.dark++
	}
	s.minLuma = math.Min(s.minLuma, luma)
	s.maxLuma = math.Max(s.maxLuma, luma)
	delta := luma - s.mean
	s.mean += delta / float64(s.samples)
	s.m2 += delta * (luma - s.mean)
}

func (s imageStats) isBlack() bool { return s.dark*1000 >= s.samples*995 }

func (s imageStats) isBlank() bool {
	return s.maxLuma-s.minLuma <= 2 || s.m2/float64(s.samples) < 0.75
}

// EncodeForGroq encodes an image as a base64 data URL under Groq's 4MB limit.
// It prefers PNG for legibility, downscales preserving aspect ratio, and falls
// back to JPEG if PNG is still too large.
func EncodeForGroq(img image.Image) (string, error) {
	if err := validateEncodingImage(img); err != nil {
		return "", err
	}
	dataURL, ok := tryPNG(img, maxBase64Bytes)
	if ok {
		return dataURL, nil
	}
	if dataURL, ok = tryScaledPNG(img); ok {
		return dataURL, nil
	}
	if dataURL, ok = tryScaledJPEG(img); ok {
		return dataURL, nil
	}
	return "", fmt.Errorf("unable to compress image under 4MB")
}

func validateEncodingImage(img image.Image) error {
	if img == nil {
		return fmt.Errorf("nil image")
	}
	bounds := img.Bounds()
	if bounds.Dx() == 0 || bounds.Dy() == 0 {
		return fmt.Errorf("image has zero dimensions")
	}
	return nil
}

func tryScaledPNG(img image.Image) (string, bool) {
	for _, maxSide := range []int{2560, 1920, 1600, 1280, 1024, 800, 640} {
		if dataURL, ok := tryPNG(scaleToFit(img, maxSide), maxBase64Bytes); ok {
			return dataURL, true
		}
	}
	return "", false
}

func tryScaledJPEG(img image.Image) (string, bool) {
	for _, maxSide := range []int{2560, 1920, 1600, 1280, 1024, 800, 640, 480} {
		if dataURL, ok := tryJPEG(scaleToFit(img, maxSide), 85, maxBase64Bytes); ok {
			return dataURL, true
		}
	}
	return "", false
}

func tryPNG(img image.Image, limit int) (string, bool) {
	var b bytes.Buffer
	if err := png.Encode(&b, img); err != nil {
		return "", false
	}
	if b.Len() > limit {
		return "", false
	}
	return "data:image/png;base64," + base64.StdEncoding.EncodeToString(b.Bytes()), true
}

func tryJPEG(img image.Image, quality int, limit int) (string, bool) {
	var b bytes.Buffer
	if err := jpeg.Encode(&b, img, &jpeg.Options{Quality: quality}); err != nil {
		return "", false
	}
	if b.Len() > limit {
		return "", false
	}
	return "data:image/jpeg;base64," + base64.StdEncoding.EncodeToString(b.Bytes()), true
}

func scaleToFit(img image.Image, maxSide int) image.Image {
	bounds := img.Bounds()
	w := bounds.Dx()
	h := bounds.Dy()
	if w <= maxSide && h <= maxSide {
		return img
	}

	scale := float64(maxSide) / float64(max(w, h))
	newW := int(float64(w) * scale)
	newH := int(float64(h) * scale)
	if newW < 1 {
		newW = 1
	}
	if newH < 1 {
		newH = 1
	}

	dst := image.NewRGBA(image.Rect(0, 0, newW, newH))
	draw.CatmullRom.Scale(dst, dst.Bounds(), img, bounds, draw.Over, nil)
	return dst
}

func max(a, b int) int {
	if a > b {
		return a
	}
	return b
}
