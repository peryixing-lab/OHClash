package main

import (
	"context"
	"fmt"
	"sync/atomic"
	"testing"
	"time"
)

func TestProbeQueueRefillsBeforeSlowNodeFinishes(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	slow := make(chan struct{})
	late := make(chan struct{}, 1)
	done := make(chan struct{})
	var active, peak, count atomic.Int32
	names := []string{}
	for i := 0; i < 20; i++ {
		names = append(names, fmt.Sprint(i))
	}
	go func() {
		runProbeQueue(ctx, names, func(ctx context.Context, name string) delayJobResult {
			n := active.Add(1)
			defer active.Add(-1)
			for {
				p := peak.Load()
				if n <= p || peak.CompareAndSwap(p, n) {
					break
				}
			}
			if name == "0" {
				select {
				case <-slow:
				case <-ctx.Done():
				}
			}
			if name == "19" {
				late <- struct{}{}
			}
			return delayJobResult{Name: name, Delay: 1}
		}, func(delayJobResult) { count.Add(1) })
		close(done)
	}()
	select {
	case <-late:
	case <-ctx.Done():
		t.Fatal("a slow first node blocked later nodes")
	}
	close(slow)
	<-done
	if peak.Load() > 8 || count.Load() != 20 {
		t.Fatalf("concurrency=%d results=%d", peak.Load(), count.Load())
	}
}

func TestProbeQueueCancellation(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	started := make(chan struct{}, 8)
	done := make(chan struct{})
	names := make([]string, 100)
	go func() {
		runProbeQueue(ctx, names, func(ctx context.Context, name string) delayJobResult {
			started <- struct{}{}
			<-ctx.Done()
			return delayJobResult{Name: name}
		}, func(delayJobResult) {})
		close(done)
	}()
	<-started
	cancel()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("cancel did not release workers")
	}
}
