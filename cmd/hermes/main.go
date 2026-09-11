// Hermes: capture, answer, type.
package main

import (
	"os"
	"runtime"
)

func main() {
	configureLogging()
	configureRuntime()
	runtime.LockOSThread()
	if isNativeMessagingInvocation(os.Args[1:]) {
		runNativeMessaging()
		return
	}
	run()
}
