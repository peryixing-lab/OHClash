//go:build openharmony

package main

// The OpenHarmony Go toolchain uses linux as runtime.GOOS. Build tags retain
// the actual target identity for platform-specific VPN configuration.
const openHarmonyTarget = true
