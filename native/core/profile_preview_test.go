package main

import (
	"encoding/base64"
	"strings"
	"testing"
)

func TestProfilePreviewFormats(t *testing.T) {
	yaml := "proxies:\n - {name: '香港 #1', type: ss, server: private.example, port: 443, cipher: aes-128-gcm, password: secret-value}\nproxy-groups:\n - {name: 选择, type: select, proxies: ['香港 #1', DIRECT]}\n"
	for _, body := range []string{yaml, base64.StdEncoding.EncodeToString([]byte(yaml)), base64.RawURLEncoding.EncodeToString([]byte(yaml))} {
		p := inspectProfile([]byte(body))
		if p.Error != "" || len(p.Groups) != 1 || p.Groups[0].All[0] != "香港 #1" {
			t.Fatalf("unexpected preview: %+v", p)
		}
		output := profilePreviewJSON([]byte(body))
		if strings.Contains(output, "private.example") || strings.Contains(output, "secret-value") {
			t.Fatal("preview exposed credentials")
		}
	}
	uri := "trojan://test-password@example.com:443#Test"
	for _, body := range []string{uri, base64.StdEncoding.EncodeToString([]byte(uri))} {
		p := inspectProfile([]byte(body))
		if p.Error != "" || len(p.Groups) != 3 || p.Groups[0].Name != "节点选择" || p.Entries[2].Name != "Test" {
			t.Fatalf("bad URI preview: %+v", p)
		}
	}
}
func TestProfilePreviewProviderAndMalformed(t *testing.T) {
	p := inspectProfile([]byte("proxy-providers:\n p: {type: http, url: 'https://invalid.example/sub'}\nproxy-groups:\n - {name: remote, type: select, use: [p]}\n"))
	if !p.Providers || len(p.Groups) != 1 || len(p.Groups[0].All) != 0 {
		t.Fatalf("bad provider preview: %+v", p)
	}
	if p := inspectProfile([]byte("<html>error</html>")); p.Error == "" {
		t.Fatal("malformed input accepted")
	}
}
