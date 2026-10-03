package main

import (
	"errors"
	"sync"
	"sync/atomic"
)

var errCoreCancelled = errors.New("VPN startup cancelled")

// A request captures its epoch before it enters the NAPI worker queue. A stop
// invalidates that epoch immediately, so a queued start cannot revive a VPN
// after the user has disconnected. The mutex also covers complete cleanup.
type coreLifecycle struct {
	mu    sync.Mutex
	epoch atomic.Uint64
}

func (l *coreLifecycle) current() uint64 { return l.epoch.Load() }
func (l *coreLifecycle) cancel() uint64  { return l.epoch.Add(1) }

func (l *coreLifecycle) run(epoch uint64, start func() error, cleanup func()) error {
	l.mu.Lock()
	defer l.mu.Unlock()
	if epoch != l.current() {
		return errCoreCancelled
	}
	err := start()
	if epoch != l.current() {
		cleanup()
		return errCoreCancelled
	}
	return err
}

func (l *coreLifecycle) stop(epoch uint64, cleanup func()) {
	l.mu.Lock()
	defer l.mu.Unlock()
	// A delayed cleanup from an older session must not stop a newer session.
	if epoch == l.current() {
		cleanup()
	}
}
