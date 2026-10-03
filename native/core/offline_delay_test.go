package main

import (
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strconv"
	"sync/atomic"
	"testing"
	"time"
)

func TestOfflineDelayUsesProxyWithoutVPN(t *testing.T) {
	var tunneled, reached atomic.Int32
	target := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { reached.Add(1); w.WriteHeader(204) }))
	defer target.Close()
	proxy := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != "CONNECT" {
			t.Errorf("expected CONNECT, got %s", r.Method)
			w.WriteHeader(400)
			return
		}
		upstream, err := net.Dial("tcp", r.Host)
		if err != nil {
			w.WriteHeader(502)
			return
		}
		client, _, err := w.(http.Hijacker).Hijack()
		if err != nil {
			upstream.Close()
			return
		}
		tunneled.Add(1)
		fmt.Fprint(client, "HTTP/1.1 200 Connection Established\r\n\r\n")
		go func() { defer upstream.Close(); defer client.Close(); io.Copy(upstream, client) }()
		io.Copy(client, upstream)
	}))
	host, port, _ := net.SplitHostPort(proxy.Listener.Addr().String())
	number, _ := strconv.Atoi(port)
	profile := []byte(fmt.Sprintf("proxies:\n - {name: probe, type: http, server: %s, port: %d}\n", host, number))
	result := testProfileDelay(profile, "probe", target.URL, time.Second)
	if result.Error != "" || tunneled.Load() != 1 || reached.Load() != 1 || result.Delay == 0 {
		t.Fatalf("test did not traverse proxy: %+v tunnels=%d reached=%d", result, tunneled.Load(), reached.Load())
	}
	proxy.Close()
	result = testProfileDelay(profile, "probe", target.URL, 100*time.Millisecond)
	if result.Error == "" || result.Delay != 0 {
		t.Fatalf("unavailable proxy produced success: %+v", result)
	}
	if reached.Load() != 1 {
		t.Fatal("failed proxy silently fell back to direct")
	}
}
