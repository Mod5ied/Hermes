package capture

import (
	"bytes"
	"encoding/base64"
	"fmt"
	"image"
	"image/jpeg"
	"image/png"

	"golang.org/x/image/draw"
)

const maxBase64Bytes = 4 * 1024 * 1024 // 4 MB

// EncodeForGroq encodes an image as a base64 data URL under Groq's 4MB limit.
// It prefers PNG for legibility, downscales preserving aspect ratio, and falls
// back to JPEG if PNG is still too large.
func EncodeForGroq(img image.Image) (string, error) {
	if img == nil {
		return "", fmt.Errorf("nil image")
	}

	bounds := img.Bounds()
	if bounds.Dx() == 0 || bounds.Dy() == 0 {
		return "", fmt.Errorf("image has zero dimensions")
	}

	// First try PNG as-is.
	dataURL, ok := tryPNG(img, maxBase64Bytes)
	if ok {
		return dataURL, nil
	}

	// Downscale PNG attempts.
	for _, maxSide := range []int{2560, 1920, 1600, 1280, 1024, 800, 640} {
		down := scaleToFit(img, maxSide)
		dataURL, ok := tryPNG(down, maxBase64Bytes)
		if ok {
			return dataURL, nil
		}
	}

	// Fall back to JPEG at quality 85.
	for _, maxSide := range []int{2560, 1920, 1600, 1280, 1024, 800, 640, 480} {
		down := scaleToFit(img, maxSide)
		dataURL, ok := tryJPEG(down, 85, maxBase64Bytes)
		if ok {
			return dataURL, nil
		}
	}

	return "", fmt.Errorf("unable to compress image under 4MB")
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
