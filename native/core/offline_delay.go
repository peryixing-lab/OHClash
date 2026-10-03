package main

import (
	"context"
	"encoding/json"
	"fmt"
	"time"
)

type offlineDelayResult struct {
	Delay uint16 `json:"delay"`
	Error string `json:"error,omitempty"`
}

// A temporary protocol adapter performs a real HTTP test. It never applies a
// config, starts a controller, creates TUN, or mutates the running VPN core.
func testProfileDelay(content []byte, name, url string, timeout time.Duration) offlineDelayResult {
	raw, err := decodeProfile(content)
	if err != nil {
		return offlineDelayResult{Error: "配置无法解析"}
	}
	var mapping map[string]any
	for _, proxy := range raw.Proxy {
		if proxy["name"] == name {
			mapping = proxy
			break
		}
	}
	if name == "DIRECT" {
		mapping = map[string]any{"name": "DIRECT", "type": "direct"}
	}
	return probeMapping(context.Background(), mapping, url, timeout, false)
}

func offlineDelayJSON(content []byte, name string) string {
	result := testProfileDelay(content, name, probeURL, probeTimeout)
	data, err := json.Marshal(result)
	if err != nil {
		return fmt.Sprintf(`{"error":%q}`, "测速结果不可用")
	}
	return string(data)
}
