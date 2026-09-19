package main

import (
	"log"
	"os"
)

// exitWithParent stops the server when the process that launched it (the
// viewer) exits, so a crashed or force-closed viewer never leaves an
// orphaned server holding the port.
func exitWithParent(pid int) {
	p, err := os.FindProcess(pid)
	if err != nil {
		log.Printf("parent %d not found: %v", pid, err)
		os.Exit(0)
	}
	go func() {
		p.Wait() // on Windows this waits on the process handle
		log.Printf("parent %d exited; shutting down", pid)
		os.Exit(0)
	}()
}
