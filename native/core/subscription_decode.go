package main

import (
	b "bytes"
	"encoding/base64"
	"unicode/utf8"
)

func decodeSubscriptionBase64(buf []byte) []byte {
	trimmed := b.TrimSpace(buf)
	compact := b.Join(b.Fields(trimmed), nil)
	for _, encoding := range []*base64.Encoding{
		base64.StdEncoding, base64.RawStdEncoding,
		base64.URLEncoding, base64.RawURLEncoding,
	} {
		decoded := make([]byte, encoding.DecodedLen(len(compact)))
		n, err := encoding.Decode(decoded, compact)
		if err != nil || !utf8.Valid(decoded[:n]) {
			continue
		}
		text := decoded[:n]
		valid := true
		for _, ch := range text {
			if ch < 32 && ch != '\t' && ch != '\n' && ch != '\r' || ch == 127 {
				valid = false
				break
			}
		}
		if valid {
			return b.TrimSpace(text)
		}
	}
	return trimmed
}
