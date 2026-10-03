package main

import (
	"encoding/json"
	"fmt"
	"github.com/metacubex/mihomo/common/convert"
	"github.com/metacubex/mihomo/config"
)

type previewEntry struct {
	Name  string `json:"name"`
	Type  string `json:"type"`
	Delay int    `json:"delay"`
}
type previewGroup struct {
	Name  string   `json:"name"`
	Type  string   `json:"type"`
	Now   string   `json:"now"`
	All   []string `json:"all"`
	Delay int      `json:"delay"`
}
type profilePreview struct {
	Groups    []previewGroup `json:"groups"`
	Entries   []previewEntry `json:"entries"`
	Providers bool           `json:"providers"`
	Error     string         `json:"error,omitempty"`
}

// Reads metadata only: no listeners, DNS, provider downloads or global config changes.
// Server addresses, passwords and subscription URLs never cross this interface.
func inspectProfile(content []byte) profilePreview {
	result := profilePreview{Groups: []previewGroup{}, Entries: []previewEntry{}}
	raw, err := decodeProfile(content)
	if err != nil {
		result.Error = err.Error()
		return result
	}
	result.Providers = len(raw.ProxyProvider) > 0
	result.Entries = append(result.Entries, previewEntry{Name: "DIRECT", Type: "Direct"}, previewEntry{Name: "REJECT", Type: "Reject"})
	names := []string{}
	for _, p := range raw.Proxy {
		name, _ := p["name"].(string)
		kind, _ := p["type"].(string)
		if name == "" {
			continue
		}
		names = append(names, name)
		result.Entries = append(result.Entries, previewEntry{Name: name, Type: kind})
	}
	for _, g := range raw.ProxyGroup {
		name, _ := g["name"].(string)
		kind, _ := g["type"].(string)
		if name == "" {
			continue
		}
		members := []string{}
		switch list := g["proxies"].(type) {
		case []any:
			for _, n := range list {
				if text, ok := n.(string); ok {
					members = append(members, text)
				}
			}
		case []string:
			members = append(members, list...)
		}
		if include, _ := g["include-all-proxies"].(bool); include {
			members = append(members, names...)
		}
		if include, _ := g["include-all"].(bool); include {
			members = append(members, names...)
		}
		result.Groups = append(result.Groups, previewGroup{Name: name, Type: kind, All: members})
		result.Entries = append(result.Entries, previewEntry{Name: name, Type: kind})
	}
	if len(result.Groups) == 0 && len(names) > 0 {
		result.Groups = append(result.Groups, previewGroup{Name: "全部节点", Type: "preview", All: names})
	}
	return result
}

func profilePreviewJSON(content []byte) string {
	result, _ := json.Marshal(inspectProfile(content))
	return string(result)
}

func decodeProfile(content []byte) (*config.RawConfig, error) {
	raw, err := config.UnmarshalRawConfig(decodeSubscriptionBase64(content))
	if err != nil {
		proxies, convertErr := convert.ConvertsV2Ray(decodeSubscriptionBase64(content))
		if convertErr != nil || len(proxies) == 0 {
			return nil, fmt.Errorf("配置不是有效的 YAML 或节点订阅")
		}
		raw = config.DefaultRawConfig()
		raw.Proxy = proxies
		names := []string{}
		for _, p := range proxies {
			names = append(names, fmt.Sprint(p["name"]))
		}
		raw.ProxyGroup = []map[string]any{
			{"name": "节点选择", "type": "select", "proxies": append([]string{"自动选择", "故障转移", "DIRECT"}, names...)},
			{"name": "自动选择", "type": "url-test", "proxies": names},
			{"name": "故障转移", "type": "fallback", "proxies": names},
		}
	}

	return raw, nil
}
