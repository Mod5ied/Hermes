//go:build darwin

package main

import (
	"log"
	"os"
	"syscall"
)

func configureLogging() {
	file, err := os.OpenFile("/tmp/hermes.log", os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0644)
	if err != nil {
		return
	}
	log.SetOutput(file)
	os.Stderr = file
	_ = syscall.Dup2(int(file.Fd()), 2)
}
