package route

import (
	"fmt"
	"net"
	"net/http"
	"strings"
	"sync"
	"testing"
	"time"
)

func TestControllerRepeatedStopAndRestart(t *testing.T) {
	t.Cleanup(CloseServers)
	address := "127.0.0.1:0"
	client := &http.Client{Timeout: time.Second, Transport: &http.Transport{DisableKeepAlives: true}}
	defer client.CloseIdleConnections()
	for attempt := 0; attempt < 20; attempt++ {
		secret := fmt.Sprintf("test-session-%d", attempt)
		ReCreateServer(&Config{Addr: address, Secret: secret})
		result := ControllerListenResult()
		if !strings.HasPrefix(result, "listening at ") {
			t.Fatalf("start %d: %s", attempt, result)
		}
		address = strings.TrimPrefix(result, "listening at ")
		request, err := http.NewRequest(http.MethodGet, "http://"+address+"/version", nil)
		if err != nil {
			t.Fatal(err)
		}
		request.Header.Set("Authorization", "Bearer "+secret)
		response, err := client.Do(request)
		if err != nil {
			t.Fatalf("request %d: %v", attempt, err)
		}
		response.Body.Close()
		if response.StatusCode != http.StatusOK {
			t.Fatalf("session %d returned %d", attempt, response.StatusCode)
		}
		CloseServers()
		CloseServers()
		if got := ControllerListenResult(); got != "" {
			t.Fatalf("stale readiness after stop: %q", got)
		}
		// Reuse the same port immediately. This also catches closing the Server
		// before its Serve goroutine registered the bound listener.
		listener, err := net.Listen("tcp", address)
		if err != nil {
			t.Fatalf("stop %d left its port bound: %v", attempt, err)
		}
		listener.Close()
	}
}

func TestControllerImmediateStopReleasesPendingListener(t *testing.T) {
	t.Cleanup(CloseServers)
	for attempt := 0; attempt < 50; attempt++ {
		ReCreateServer(&Config{Addr: "127.0.0.1:0"})
		address := strings.TrimPrefix(ControllerListenResult(), "listening at ")
		CloseServers()
		listener, err := net.Listen("tcp", address)
		if err != nil {
			t.Fatalf("pending controller retained port: %v", err)
		}
		listener.Close()
	}
}

func TestControllerConcurrentStartAndStop(t *testing.T) {
	t.Cleanup(CloseServers)
	var workers sync.WaitGroup
	for attempt := 0; attempt < 20; attempt++ {
		workers.Add(2)
		go func() { defer workers.Done(); ReCreateServer(&Config{Addr: "127.0.0.1:0"}) }()
		go func() { defer workers.Done(); CloseServers() }()
	}
	workers.Wait()
	CloseServers()
	controllerMu.Lock()
	defer controllerMu.Unlock()
	if len(controllerListeners) != 0 || httpServer != nil {
		t.Fatal("controller listeners survived final cleanup")
	}
}
