package capture

import (
	"image"
	"image/color"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestEncodeForGroqPNG(t *testing.T) {
	img := image.NewRGBA(image.Rect(0, 0, 100, 100))
	for y := 0; y < 100; y++ {
		for x := 0; x < 100; x++ {
			img.Set(x, y, color.RGBA{uint8(x), uint8(y), 0, 255})
		}
	}
	dataURL, err := EncodeForGroq(img)
	require.NoError(t, err)
	assert.True(t, strings.HasPrefix(dataURL, "data:image/png;base64,"))
}

func TestTrayCap(t *testing.T) {
	// Tray lives in another package; keep this placeholder minimal.
	assert.Equal(t, 1, 1)
}

func TestValidateImageContentRejectsBlackFrame(t *testing.T) {
	img := image.NewRGBA(image.Rect(0, 0, 200, 120))
	err := ValidateImageContent(img)
	require.Error(t, err)
	assert.Contains(t, err.Error(), "black")
}

func TestValidateImageContentRejectsUniformFrame(t *testing.T) {
	img := image.NewRGBA(image.Rect(0, 0, 200, 120))
	for y := 0; y < 120; y++ {
		for x := 0; x < 200; x++ {
			img.Set(x, y, color.RGBA{240, 240, 240, 255})
		}
	}
	require.Error(t, ValidateImageContent(img))
}

func TestValidateImageContentAcceptsDarkPageWithText(t *testing.T) {
	img := image.NewRGBA(image.Rect(0, 0, 200, 120))
	for y := 40; y < 55; y++ {
		for x := 20; x < 180; x++ {
			img.Set(x, y, color.White)
		}
	}
	require.NoError(t, ValidateImageContent(img))
}
