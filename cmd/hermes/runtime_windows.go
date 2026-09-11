//go:build windows

package main

import (
	"log"
	"os"
	"runtime"
	"runtime/debug"
	"strconv"
	"strings"
)

const (
	defaultWindowsGoThreads = 2
	defaultMemoryLimitMB    = 384
	minimumMemoryLimitMB    = 192
	maximumMemoryLimitMB    = 1024
)

func configureRuntime() {
	if strings.TrimSpace(os.Getenv("GOMAXPROCS")) == "" {
		threads := min(defaultWindowsGoThreads, runtime.NumCPU())
		if threads < 1 {
			threads = 1
		}
		runtime.GOMAXPROCS(threads)
	}
	limitMB := defaultMemoryLimitMB
	if value, err := strconv.Atoi(strings.TrimSpace(os.Getenv("HERMES_MEMORY_LIMIT_MB"))); err == nil && value > 0 {
		limitMB = value
	}
	limitMB = max(minimumMemoryLimitMB, min(maximumMemoryLimitMB, limitMB))
	debug.SetMemoryLimit(int64(limitMB) << 20)
	log.Printf("windows runtime: gomaxprocs=%d go_memory_limit=%dMiB", runtime.GOMAXPROCS(0), limitMB)
}
