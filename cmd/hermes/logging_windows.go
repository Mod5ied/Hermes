//go:build windows

package main

import (
	"log"
	"os"
	"path/filepath"
)

func configureLogging() {
	root, err := os.UserCacheDir()
	if err != nil {
		return
	}
	directory := filepath.Join(root, "Hermes")
	if err := os.MkdirAll(directory, 0700); err != nil {
		return
	}
	file, err := os.OpenFile(filepath.Join(directory, "hermes.log"), os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0600)
	if err != nil {
		return
	}
	log.SetOutput(file)
	os.Stderr = file
}
