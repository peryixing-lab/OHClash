package main

import (
	"errors"
	"sync/atomic"
	"testing"
	"time"
)

func TestLifecycleStopCancelsQueuedStart(t *testing.T) {
	var lifecycle coreLifecycle
	epoch := lifecycle.current()
	lifecycle.cancel()
	started := false
	err := lifecycle.run(epoch, func() error { started = true; return nil }, func() {})
	if started || !errors.Is(err, errCoreCancelled) {
		t.Fatalf("cancelled work started=%v err=%v", started, err)
	}
}

func TestLifecycleStopWaitsForLaunchAndCleansBeforeReturning(t *testing.T) {
	var lifecycle coreLifecycle
	epoch := lifecycle.current()
	entered, release := make(chan struct{}), make(chan struct{})
	var active atomic.Bool
	finished := make(chan error, 1)
	cleanup := func() { active.Store(false) }
	go func() {
		finished <- lifecycle.run(epoch, func() error {
			close(entered)
			<-release
			active.Store(true)
			return nil
		}, cleanup)
	}()
	<-entered
	stopEpoch := lifecycle.cancel()
	stopped := make(chan struct{})
	go func() { lifecycle.stop(stopEpoch, cleanup); close(stopped) }()
	select {
	case <-stopped:
		t.Fatal("stop returned while launch was still running")
	case <-time.After(20 * time.Millisecond):
	}
	close(release)
	if err := <-finished; !errors.Is(err, errCoreCancelled) {
		t.Fatalf("launch returned %v", err)
	}
	<-stopped
	if active.Load() {
		t.Fatal("a cancelled launch left a running core")
	}
	if err := lifecycle.run(lifecycle.current(), func() error { active.Store(true); return nil }, cleanup); err != nil {
		t.Fatalf("reconnect after stop failed: %v", err)
	}
	if !active.Load() {
		t.Fatal("reconnect did not start")
	}
}

func TestLifecycleStaleStopDoesNotStopNewSession(t *testing.T) {
	var lifecycle coreLifecycle
	old := lifecycle.cancel()
	current := lifecycle.cancel()
	var active bool
	if err := lifecycle.run(current, func() error { active = true; return nil }, func() { active = false }); err != nil {
		t.Fatal(err)
	}
	lifecycle.stop(old, func() { active = false })
	if !active {
		t.Fatal("an old session's cleanup stopped the new VPN")
	}
	lifecycle.stop(current, func() { active = false })
	lifecycle.stop(current, func() { active = false })
	if active {
		t.Fatal("current stop did not clean up")
	}
}
