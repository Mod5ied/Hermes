package tray

import (
	"testing"

	"github.com/stretchr/testify/assert"
)

func TestTrayAddAndCap(t *testing.T) {
	tr := New()
	for i := 0; i < MaxShots+2; i++ {
		count, err := tr.Add("shot")
		assert.NoError(t, err)
		if i < MaxShots {
			assert.Equal(t, i+1, count)
		} else {
			assert.Equal(t, MaxShots, count)
		}
	}
	assert.Len(t, tr.Shots(), MaxShots)
	tr.Clear()
	assert.Equal(t, 0, tr.Count())
}

func TestTrayEmptyRejected(t *testing.T) {
	tr := New()
	_, err := tr.Add("")
	assert.Error(t, err)
}
