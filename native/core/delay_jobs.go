package main

import (
	"context"
	"encoding/json"
	"fmt"
	"sync"
	"sync/atomic"
	"time"

	"github.com/metacubex/mihomo/adapter"
)

const probeURL = "https://www.gstatic.com/generate_204"
const probeTimeout = 10 * time.Second
const probeWorkers = 8

type delayJobResult struct {
	Name  string `json:"name"`
	Delay uint16 `json:"delay"`
	Error string `json:"error,omitempty"`
}
type delayJobSnapshot struct {
	Results []delayJobResult `json:"results"`
	Done    bool             `json:"done"`
	Total   int              `json:"total"`
}
type delayJob struct {
	mu      sync.Mutex
	results []delayJobResult
	done    bool
	total   int
	cancel  context.CancelFunc
}

var delayJobs sync.Map
var delayJobID atomic.Uint64

// Bounded rolling workers run in Go, avoiding the NAPI worker pool's four-thread
// bottleneck and leaving it available for controller startup and UI work.
func runProbeQueue(ctx context.Context, names []string, probe func(context.Context, string) delayJobResult, emit func(delayJobResult)) {
	jobs := make(chan string)
	var workers sync.WaitGroup
	for i := 0; i < probeWorkers; i++ {
		workers.Add(1)
		go func() {
			defer workers.Done()
			for name := range jobs {
				if ctx.Err() != nil {
					return
				}
				emit(probe(ctx, name))
			}
		}()
	}
	for _, name := range names {
		select {
		case jobs <- name:
		case <-ctx.Done():
			close(jobs)
			workers.Wait()
			return
		}
	}
	close(jobs)
	workers.Wait()
}

func startDelayJob(content []byte, namesJSON string) string {
	var names []string
	if json.Unmarshal([]byte(namesJSON), &names) != nil {
		return ""
	}
	unique := []string{}
	seen := map[string]bool{}
	for _, name := range names {
		if !seen[name] {
			seen[name] = true
			unique = append(unique, name)
		}
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Minute)
	job := &delayJob{total: len(unique), results: []delayJobResult{}, cancel: cancel}
	id := fmt.Sprint(delayJobID.Add(1))
	delayJobs.Store(id, job)
	go func() {
		defer cancel()
		raw, err := decodeProfile(content)
		mappings := map[string]map[string]any{"DIRECT": {"name": "DIRECT", "type": "direct"}}
		if err == nil {
			for _, p := range raw.Proxy {
				if name, ok := p["name"].(string); ok {
					mappings[name] = p
				}
			}
		}
		runProbeQueue(ctx, unique, func(ctx context.Context, name string) delayJobResult {
			if err != nil {
				return delayJobResult{Name: name, Error: "配置无法解析"}
			}
			result := probeMapping(ctx, mappings[name], probeURL, probeTimeout, true)
			return delayJobResult{Name: name, Delay: result.Delay, Error: result.Error}
		}, func(result delayJobResult) { job.mu.Lock(); job.results = append(job.results, result); job.mu.Unlock() })
		job.mu.Lock()
		job.done = true
		job.mu.Unlock()
		// Clean up even if the page/process stopped polling unexpectedly.
		time.AfterFunc(time.Minute, func() { delayJobs.Delete(id) })
	}()
	return id
}
func pollDelayJob(id string) string {
	value, ok := delayJobs.Load(id)
	if !ok {
		return `{"results":[],"done":true,"total":0}`
	}
	job := value.(*delayJob)
	job.mu.Lock()
	snapshot := delayJobSnapshot{Results: job.results, Done: job.done, Total: job.total}
	job.results = []delayJobResult{}
	job.mu.Unlock()
	if snapshot.Done {
		delayJobs.Delete(id)
	}
	data, _ := json.Marshal(snapshot)
	return string(data)
}
func cancelDelayJob(id string) {
	if value, ok := delayJobs.LoadAndDelete(id); ok {
		value.(*delayJob).cancel()
	}
}

func probeMapping(parent context.Context, mapping map[string]any, url string, timeout time.Duration, retry bool) offlineDelayResult {
	if mapping == nil {
		return offlineDelayResult{Error: "节点未包含在本地配置中，请更新订阅后重试"}
	}
	if chain, _ := mapping["dialer-proxy"].(string); chain != "" {
		return offlineDelayResult{Error: "链式代理请连接后测速"}
	}
	attempts := 1
	if retry {
		attempts = 2
	}
	for attempt := 0; attempt < attempts; attempt++ {
		if parent.Err() != nil {
			return offlineDelayResult{Error: "测速已取消"}
		}
		proxy, err := adapter.ParseProxy(mapping)
		if err != nil {
			return offlineDelayResult{Error: "节点协议参数无效"}
		}
		ctx, cancel := context.WithTimeout(parent, timeout)
		delay, testErr := proxy.URLTest(ctx, url, nil)
		cancel()
		_ = proxy.Close()
		if testErr == nil {
			if delay == 0 {
				delay = 1
			}
			return offlineDelayResult{Delay: delay}
		}
	}
	return offlineDelayResult{Error: "节点请求失败或超时（已重试）"}
}
