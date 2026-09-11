package main

import (
	"bytes"
	"encoding/binary"
	"encoding/json"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestNativeMessagingInvocation(t *testing.T) {
	assert.True(t, isNativeMessagingInvocation([]string{"chrome-extension://abcdefghijklmnop/"}))
	assert.True(t, isNativeMessagingInvocation([]string{"--native-messaging"}))
	assert.True(t, isNativeMessagingInvocation([]string{"/Users/test/Library/Application Support/Mozilla/NativeMessagingHosts/com.hermes.app.json", "hermes@project-hermes.dev"}))
	assert.False(t, isNativeMessagingInvocation([]string{"--parent-window=0"}))
}

func TestNativeMessageRoundTrip(t *testing.T) {
	input, err := json.Marshal(nativeCommand{ID: 7, Type: "SET_STEALTH", Enabled: true})
	require.NoError(t, err)
	var framed bytes.Buffer
	require.NoError(t, binary.Write(&framed, binary.LittleEndian, uint32(len(input))))
	_, err = framed.Write(input)
	require.NoError(t, err)

	var decoded nativeCommand
	require.NoError(t, readNativeMessage(&framed, &decoded))
	assert.Equal(t, 7, decoded.ID)
	assert.Equal(t, "SET_STEALTH", decoded.Type)
	assert.True(t, decoded.Enabled)
}

func TestNativeMessageRejectsOversizedInput(t *testing.T) {
	var framed bytes.Buffer
	require.NoError(t, binary.Write(&framed, binary.LittleEndian, uint32(maxNativeInputBytes+1)))
	err := readNativeMessage(&framed, &nativeCommand{})
	assert.ErrorContains(t, err, "invalid native message size")
}

func TestNativeWriterFramesJSON(t *testing.T) {
	var output bytes.Buffer
	writer := &nativeWriter{w: &output}
	require.NoError(t, writer.respond(4, true, "", true))
	var response map[string]any
	require.NoError(t, readNativeMessage(&output, &response))
	assert.Equal(t, "RESPONSE", response["type"])
	assert.Equal(t, float64(4), response["id"])
	assert.Equal(t, true, response["visible"])
}

func TestNativeMessageRejectsMalformedJSON(t *testing.T) {
	payload := "not-json"
	var framed bytes.Buffer
	require.NoError(t, binary.Write(&framed, binary.LittleEndian, uint32(len(payload))))
	_, err := framed.WriteString(payload)
	require.NoError(t, err)
	err = readNativeMessage(&framed, &nativeCommand{})
	assert.True(t, strings.Contains(err.Error(), "decode native message"))
}
