//go:build openharmony && cgo

package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
	"unsafe"

	t "core/tun"
	"github.com/metacubex/mihomo/hub/route"
	"github.com/metacubex/mihomo/listener/sing_tun"
)

var ohosCalls sync.Map
var ohosCallID atomic.Uint64
var ohosSecret atomic.Pointer[string]
var ohosLifecycle coreLifecycle
var ohosTun *sing_tun.Listener
var ohosTunError atomic.Pointer[string]

func main() {}

func (response MethodResponse) send() {
	data, err := response.JSON()
	if err != nil {
		data = []byte(fmt.Sprintf(`{"error":{"code":"marshal_error","message":%q}}`, err.Error()))
	}
	if value, found := ohosCalls.Load(response.ID); found {
		value.(chan string) <- string(data)
	}
}

func deliverEvent(data []byte) {}

func ohosControllerSecret() string {
	if value := ohosSecret.Load(); value != nil {
		return *value
	}
	return ""
}

//export FlClashLaunch
func FlClashLaunch(homeDir *C.char, secret *C.char) *C.char {
	return FlClashLaunchAtEpoch(homeDir, secret, C.ulonglong(ohosLifecycle.current()))
}

//export FlClashLifecycleEpoch
func FlClashLifecycleEpoch() C.ulonglong { return C.ulonglong(ohosLifecycle.current()) }

//export FlClashCancelLifecycle
func FlClashCancelLifecycle() C.ulonglong { return C.ulonglong(ohosLifecycle.cancel()) }

//export FlClashLaunchAtEpoch
func FlClashLaunchAtEpoch(homeDir *C.char, secret *C.char, epoch C.ulonglong) *C.char {
	err := ohosLifecycle.run(uint64(epoch), func() error {
		if isInit.Load() {
			return errors.New("native core is already initialized")
		}
		if err := launchOHOSCore(C.GoString(homeDir), C.GoString(secret)); err != nil {
			stopOHOSCore()
			return err
		}
		return nil
	}, stopOHOSCore)
	if err != nil {
		return C.CString(err.Error())
	}
	return C.CString("")
}

func launchOHOSCore(homeDir, secret string) error {
	resetPhysicalNetwork()
	value := secret
	ohosSecret.Store(&value)
	params := &InitParams{HomeDir: homeDir, Version: 26}
	if !handleInitClash(params) {
		return errors.New("core initialization failed")
	}
	setup := defaultSetupParams()
	if data, err := os.ReadFile(filepath.Join(params.HomeDir, "proxy-selections.json")); err == nil {
		_ = json.Unmarshal(data, &setup.SelectedMap)
	}
	if setupError := handleSetupConfig(setup); setupError != "" {
		return errors.New(setupError)
	}
	// The route package starts the controller in a goroutine. Do not report a
	// successful launch until it has bound the port needed by the ArkTS UI.
	for attempt := 0; attempt < 30; attempt++ {
		result := route.ControllerListenResult()
		if strings.HasPrefix(result, "external controller listen failed:") ||
			strings.HasPrefix(result, "external controller serve failed:") {
			return errors.New(result)
		}
		if strings.HasPrefix(result, "listening at ") {
			connection, err := net.DialTimeout("tcp", "127.0.0.1:9090", time.Second)
			if err != nil {
				return fmt.Errorf("external controller is bound but unreachable: %w", err)
			}
			_ = connection.Close()
			return nil
		}
		time.Sleep(100 * time.Millisecond)
	}
	address := "<nil>"
	if currentConfig != nil && currentConfig.Controller != nil {
		address = currentConfig.Controller.ExternalController
	}
	return fmt.Errorf("external controller did not start within 3 seconds (GOOS=%s, addr=%q)", runtime.GOOS, address)
}

//export FlClashStartTun
func FlClashStartTun(fd C.int) C.int {
	return FlClashStartTunAtEpoch(fd, C.ulonglong(ohosLifecycle.current()))
}

//export FlClashStartTunAtEpoch
func FlClashStartTunAtEpoch(fd C.int, epoch C.ulonglong) C.int {
	// The native API consumes fd on every path, including cancelled work.
	owned := true
	defer func() {
		if owned {
			_ = syscall.Close(int(fd))
		}
	}()
	err := ohosLifecycle.run(uint64(epoch), func() error {
		if !isInit.Load() {
			return errors.New("native core is not initialized")
		}
		if ohosTun != nil {
			return errors.New("TUN is already running")
		}
		owned = false
		listener, err := t.StartWithError(int(fd), "system", "172.19.0.1/30", "172.19.0.2")
		if err != nil {
			return err
		}
		ohosTun = listener
		handleStartListener()
		return nil
	}, stopOHOSCore)
	if err != nil {
		message := err.Error()
		ohosTunError.Store(&message)
		return 0
	}
	ohosTunError.Store(nil)
	return 1
}

//export FlClashGetTunError
func FlClashGetTunError() *C.char {
	if message := ohosTunError.Load(); message != nil {
		return C.CString(*message)
	}
	return C.CString("")
}

//export FlClashStop
func FlClashStop() {
	FlClashStopAtEpoch(FlClashCancelLifecycle())
}

//export FlClashStopAtEpoch
func FlClashStopAtEpoch(epoch C.ulonglong) { ohosLifecycle.stop(uint64(epoch), stopOHOSCore) }

func stopOHOSCore() {
	if ohosTun != nil {
		_ = ohosTun.Close()
		ohosTun = nil
	}
	route.CloseServers()
	if isInit.Load() {
		handleCloseConnections()
		handleResetConnections()
		handleShutdown()
	}
	ohosSecret.Store(nil)
	ohosTunError.Store(nil)
	resetPhysicalNetwork()
}

//export FlClashInvoke
func FlClashInvoke(input *C.char) *C.char {
	call := &MethodCall{}
	if err := json.Unmarshal([]byte(C.GoString(input)), call); err != nil {
		return C.CString(fmt.Sprintf(`{"error":{"code":"invalid_method_call","message":%q}}`, err.Error()))
	}
	call.ID = fmt.Sprintf("ohos-%d", ohosCallID.Add(1))
	result := make(chan string, 1)
	ohosCalls.Store(call.ID, result)
	defer ohosCalls.Delete(call.ID)
	go handleMethodCall(call, newMethodResponse(call.ID, nil))
	select {
	case value := <-result:
		return C.CString(value)
	case <-time.After(60 * time.Second):
		return C.CString(`{"error":{"code":"timeout","message":"Core call timed out"}}`)
	}
}

//export FlClashFree
func FlClashFree(value *C.char) {
	C.free(unsafe.Pointer(value))
}

//export FlClashInspectProfile
func FlClashInspectProfile(content *C.char) *C.char {
	return C.CString(profilePreviewJSON([]byte(C.GoString(content))))
}

//export FlClashTestProfileDelay
func FlClashTestProfileDelay(content *C.char, name *C.char) *C.char {
	return C.CString(offlineDelayJSON([]byte(C.GoString(content)), C.GoString(name)))
}

//export FlClashBeginDelayJob
func FlClashBeginDelayJob(content *C.char, names *C.char) *C.char {
	return C.CString(startDelayJob([]byte(C.GoString(content)), C.GoString(names)))
}

//export FlClashPollDelayJob
func FlClashPollDelayJob(id *C.char) *C.char { return C.CString(pollDelayJob(C.GoString(id))) }

//export FlClashCancelDelayJob
func FlClashCancelDelayJob(id *C.char) { cancelDelayJob(C.GoString(id)) }
