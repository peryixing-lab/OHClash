package openvpn

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"math/big"
	"strings"
	"testing"
	"time"
)

// Generate test credentials in memory instead of publishing a fixed private key.
var testCert, testKey = generateTestCertificate()

func generateTestCertificate() (string, string) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		panic(err)
	}
	template := &x509.Certificate{
		SerialNumber:          big.NewInt(1),
		Subject:               pkix.Name{CommonName: "openvpn.example.test"},
		NotBefore:             time.Now().Add(-time.Hour),
		NotAfter:              time.Now().Add(24 * time.Hour),
		KeyUsage:              x509.KeyUsageDigitalSignature | x509.KeyUsageCertSign,
		ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth, x509.ExtKeyUsageServerAuth},
		BasicConstraintsValid: true,
		IsCA:                  true,
	}
	cert, err := x509.CreateCertificate(rand.Reader, template, template, &key.PublicKey, key)
	if err != nil {
		panic(err)
	}
	keyDER, err := x509.MarshalECPrivateKey(key)
	if err != nil {
		panic(err)
	}
	return string(pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: cert})),
		string(pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: keyDER}))
}

func testTLSCryptBlock() string {
	return `-----BEGIN OpenVPN Static key V1-----
` + strings.Repeat("00", 256) + `
-----END OpenVPN Static key V1-----`
}

func yamlStyleConfig() *ClientConfig {
	return &ClientConfig{
		RemoteHost: "vpn.example.com",
		RemotePort: 1194,
		Proto:      "udp",
		Dev:        "tun",
		Cipher:     "AES-128-GCM",
		Auth:       "SHA256",
		CA:         []byte(testCert),
		Cert:       []byte(testCert),
		Key:        []byte(testKey),
		TLSCrypt:   []byte(testTLSCryptBlock()),
	}
}

func TestClientConfigYAMLStyleInstallScriptSubset(t *testing.T) {
	cfg := yamlStyleConfig()
	if err := cfg.Prepare(); err != nil {
		t.Fatal(err)
	}
	if cfg.RemoteAddress() != "vpn.example.com:1194" {
		t.Fatalf("unexpected remote address: %s", cfg.RemoteAddress())
	}
	if cfg.Proto != ProtoUDP {
		t.Fatalf("unexpected proto: %s", cfg.Proto)
	}
	if cfg.Cipher != CipherAES128GCM || cfg.Auth != AuthSHA256 {
		t.Fatalf("unexpected crypto: %s/%s", cfg.Cipher, cfg.Auth)
	}
	if len(cfg.TLSCryptKey) != 256 {
		t.Fatalf("unexpected tls-crypt key length: %d", len(cfg.TLSCryptKey))
	}
}

func TestClientConfigDefaults(t *testing.T) {
	cfg := yamlStyleConfig()
	cfg.Proto = ""
	cfg.Dev = ""
	cfg.Cipher = ""
	cfg.Auth = ""

	if err := cfg.Prepare(); err != nil {
		t.Fatal(err)
	}
	if cfg.Proto != ProtoUDP || cfg.Dev != "tun" || cfg.Cipher != CipherAES128GCM || cfg.Auth != AuthSHA256 {
		t.Fatalf("unexpected defaults: proto=%s dev=%s cipher=%s auth=%s", cfg.Proto, cfg.Dev, cfg.Cipher, cfg.Auth)
	}
}

func TestClientConfigRejectsUnsupportedProto(t *testing.T) {
	cfg := yamlStyleConfig()
	cfg.Proto = "tcp-server"
	err := cfg.Prepare()
	if err == nil {
		t.Fatal("expected unsupported proto error")
	}
	if !strings.Contains(err.Error(), "unsupported openvpn proto") {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestClientConfigRejectsNegativeTransitionWindow(t *testing.T) {
	cfg := yamlStyleConfig()
	cfg.TransitionWindow = -time.Second
	if err := cfg.Prepare(); err == nil || !strings.Contains(err.Error(), "transition window") {
		t.Fatalf("negative transition window accepted: %v", err)
	}
}

func TestClientConfigAllowsMissingTLSCrypt(t *testing.T) {
	cfg := yamlStyleConfig()
	cfg.TLSCrypt = nil
	if err := cfg.Prepare(); err != nil {
		t.Fatal(err)
	}
	if len(cfg.TLSCryptKey) != 0 {
		t.Fatalf("unexpected tls-crypt key length: %d", len(cfg.TLSCryptKey))
	}
}

func TestClientConfigAuthUserPassAES256(t *testing.T) {
	cfg := &ClientConfig{
		RemoteHost: "vpn.example.com",
		RemotePort: 31194,
		Proto:      "udp",
		Dev:        "tun",
		Cipher:     "AES-256-GCM",
		Auth:       "SHA256",
		CA:         []byte(testCert),
		Username:   "user",
		Password:   "secret",
		TLSCrypt:   []byte(testTLSCryptBlock()),
	}
	if err := cfg.Prepare(); err != nil {
		t.Fatal(err)
	}
	if cfg.Cipher != CipherAES256GCM {
		t.Fatalf("unexpected cipher: %s", cfg.Cipher)
	}
	if cfg.DataCipherKeyLength() != 32 {
		t.Fatalf("unexpected data key length helper: %d", cfg.DataCipherKeyLength())
	}
}

func TestClientConfigAESCBCSHA1(t *testing.T) {
	cfg := &ClientConfig{
		RemoteHost: "vpn.example.com",
		RemotePort: 1194,
		Proto:      "udp",
		Dev:        "tun",
		Cipher:     "AES-CBC",
		Auth:       "sha-1",
		CA:         []byte(testCert),
		Username:   "user",
		Password:   "secret",
		TLSCrypt:   []byte(testTLSCryptBlock()),
	}
	if err := cfg.Prepare(); err != nil {
		t.Fatal(err)
	}
	if cfg.Cipher != CipherAES128CBC || cfg.Auth != AuthSHA1 {
		t.Fatalf("unexpected crypto: %s/%s", cfg.Cipher, cfg.Auth)
	}
	if cfg.DataCipherKeyLength() != 16 {
		t.Fatalf("unexpected data key length helper: %d", cfg.DataCipherKeyLength())
	}
}

func TestClientConfigRequiresAuth(t *testing.T) {
	cfg := yamlStyleConfig()
	cfg.Cert = nil
	cfg.Key = nil
	cfg.Username = ""
	err := cfg.Prepare()
	if err == nil {
		t.Fatal("expected missing auth error")
	}
	if !strings.Contains(err.Error(), "cert+key or username") {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestClientConfigAuthUserPassChaCha20Poly1305(t *testing.T) {
	cfg := &ClientConfig{
		RemoteHost: "vpn.example.com",
		RemotePort: 31194,
		Proto:      "udp",
		Dev:        "tun",
		Cipher:     "chacha20-poly1305",
		Auth:       "SHA256",
		CA:         []byte(testCert),
		Username:   "user",
		Password:   "secret",
		TLSCrypt:   []byte(testTLSCryptBlock()),
	}
	if err := cfg.Prepare(); err != nil {
		t.Fatal(err)
	}
	if cfg.Cipher != CipherChaCha20Poly1305 {
		t.Fatalf("unexpected cipher: %s", cfg.Cipher)
	}
	if cfg.DataCipherKeyLength() != 32 {
		t.Fatalf("unexpected data key length helper: %d", cfg.DataCipherKeyLength())
	}
}

func TestClientConfigTLSAuth(t *testing.T) {
	cfg := &ClientConfig{
		RemoteHost:   "vpn.example.com",
		RemotePort:   1194,
		Proto:        "udp",
		Dev:          "tun",
		Cipher:       "AES-128-GCM",
		Auth:         "SHA256",
		CA:           []byte(testCert),
		Username:     "user",
		Password:     "secret",
		TLSAuth:      []byte(testTLSCryptBlock()),
		KeyDirection: "1",
	}
	if err := cfg.Prepare(); err != nil {
		t.Fatal(err)
	}
	if len(cfg.TLSAuthKey) != 256 {
		t.Fatalf("unexpected tls-auth key length: %d", len(cfg.TLSAuthKey))
	}
}

func TestClientConfigRejectsTLSAuthTLSCryptTogether(t *testing.T) {
	cfg := &ClientConfig{
		RemoteHost:   "vpn.example.com",
		RemotePort:   1194,
		Proto:        "udp",
		Dev:          "tun",
		Cipher:       "AES-128-GCM",
		Auth:         "SHA256",
		CA:           []byte(testCert),
		Username:     "user",
		Password:     "secret",
		TLSAuth:      []byte(testTLSCryptBlock()),
		TLSCrypt:     []byte(testTLSCryptBlock()),
		KeyDirection: "1",
	}
	err := cfg.Prepare()
	if err == nil {
		t.Fatal("expected mutual exclusion error")
	}
	if !strings.Contains(err.Error(), "mutually exclusive") {
		t.Fatalf("unexpected error: %v", err)
	}
}
