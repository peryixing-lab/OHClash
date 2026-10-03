//go:build openharmony && cgo

package main

/*
#cgo LDFLAGS: -lnet_connection -lhilog_ndk.z
#include <stdint.h>
#include <network/netmanager/net_connection.h>
#include <hilog/log.h>

// A VPN becomes the default network after create(). Pick an underlying
// Internet network explicitly; binding to the default would loop back to TUN.
static int flclash_find_physical_net(int32_t *net_id, int32_t *api_code) {
    NetConn_NetHandleList list = {0};
    int32_t result = OH_NetConn_GetAllNets(&list);
    if (result != 0) {
        *api_code = result;
        return 1;
    }
    if (list.netHandleListSize < 0 || list.netHandleListSize > NETCONN_MAX_NET_SIZE) {
        *api_code = list.netHandleListSize;
        return 2;
    }

    int best_score = -1;
    int32_t first_capability_error = 0;
    for (int32_t index = 0; index < list.netHandleListSize; index++) {
        NetConn_NetHandle handle = list.netHandles[index];
        if (handle.netId <= 0) {
            continue;
        }
        NetConn_NetCapabilities caps = {0};
        result = OH_NetConn_GetNetCapabilities(&handle, &caps);
        if (result != 0) {
            if (first_capability_error == 0) {
                first_capability_error = result;
            }
            continue;
        }
        if (caps.netCapsSize < 0 || caps.netCapsSize > NETCONN_MAX_CAP_SIZE ||
            caps.bearerTypesSize < 0 || caps.bearerTypesSize > NETCONN_MAX_BEARER_TYPE_SIZE) {
            continue;
        }
        int internet = 0;
        int not_vpn = 0;
        int validated = 0;
        int physical_bearer = 0;
        int score = 0;
        for (int32_t cap = 0; cap < caps.netCapsSize; cap++) {
            internet |= caps.netCaps[cap] == NETCONN_NET_CAPABILITY_INTERNET;
            not_vpn |= caps.netCaps[cap] == NETCONN_NET_CAPABILITY_NOT_VPN;
            validated |= caps.netCaps[cap] == NETCONN_NET_CAPABILITY_VALIDATED;
        }
        for (int32_t bearer = 0; bearer < caps.bearerTypesSize; bearer++) {
            switch (caps.bearerTypes[bearer]) {
                case NETCONN_BEARER_ETHERNET:
                    physical_bearer = 1;
                    if (score < 30) score = 30;
                    break;
                case NETCONN_BEARER_WIFI:
                    physical_bearer = 1;
                    if (score < 20) score = 20;
                    break;
                case NETCONN_BEARER_CELLULAR:
                    physical_bearer = 1;
                    if (score < 10) score = 10;
                    break;
                default:
                    break;
            }
        }
        if (!internet || !not_vpn || !physical_bearer) {
            continue;
        }
        if (validated) score += 100;
        if (score > best_score) {
            best_score = score;
            *net_id = handle.netId;
        }
    }
    if (best_score < 0) {
        *api_code = first_capability_error;
        return 3;
    }
    *api_code = 0;
    return 0;
}

static int32_t flclash_bind_physical_socket(int fd, int32_t net_id) {
    NetConn_NetHandle handle = { .netId = net_id };
    return OH_NetConn_BindSocket(fd, &handle);
}

static void flclash_log_socket_bind_failure(int stage, int code) {
    OH_LOG_Print(LOG_APP, LOG_ERROR, 0xF1C1, "FlClashCore",
        "Physical socket binding failed: stage=%{public}d code=%{public}d", stage, code);
}

static void flclash_log_socket_bind_ready(int net_id) {
    OH_LOG_Print(LOG_APP, LOG_INFO, 0xF1C1, "FlClashCore",
        "Outgoing sockets bound to physical network id=%{public}d", net_id);
}
*/
import "C"

import (
	"errors"
	"fmt"
	"net"
	"net/netip"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/metacubex/mihomo/component/dialer"
)

const physicalNetworkCacheDuration = 5 * time.Second

var physicalNetwork struct {
	mu      sync.Mutex
	id      int32
	expires time.Time
}

var physicalBindingFailed atomic.Bool
var physicalBindingLogged atomic.Bool

type physicalBindError struct {
	stage int
	code  int32
}

func (e physicalBindError) Error() string {
	return fmt.Sprintf("physical network socket binding failed (stage=%d, code=%d)", e.stage, e.code)
}

// Only mihomo's outbound dialer uses this hook. Local loopback and the TUN
// subnet must keep their ordinary routing, especially with the system stack's
// local TCP forwarder. UDP wildcard listeners are outbound packet sockets.
func needsPhysicalBinding(network, address string) bool {
	host, _, err := net.SplitHostPort(address)
	if err != nil {
		return true
	}
	ip, err := netip.ParseAddr(host)
	if err != nil {
		return true
	}
	if ip.IsLoopback() || ip.IsLinkLocalUnicast() {
		return false
	}
	if ip.IsUnspecified() {
		return strings.HasPrefix(network, "udp")
	}
	if netip.MustParsePrefix("172.19.0.0/30").Contains(ip) {
		return false
	}
	return true
}

func selectedPhysicalNetwork() (int32, error) {
	physicalNetwork.mu.Lock()
	defer physicalNetwork.mu.Unlock()
	if physicalNetwork.id > 0 && time.Now().Before(physicalNetwork.expires) {
		return physicalNetwork.id, nil
	}
	var id C.int32_t
	var code C.int32_t
	stage := int(C.flclash_find_physical_net(&id, &code))
	if stage != 0 {
		physicalNetwork.id = 0
		return 0, physicalBindError{stage: stage, code: int32(code)}
	}
	physicalNetwork.id = int32(id)
	physicalNetwork.expires = time.Now().Add(physicalNetworkCacheDuration)
	return int32(id), nil
}

func invalidatePhysicalNetwork(id int32) {
	physicalNetwork.mu.Lock()
	if physicalNetwork.id == id {
		physicalNetwork.id = 0
	}
	physicalNetwork.mu.Unlock()
}

// A new VPN session may start on a different network even while a previously
// selected Wi-Fi handle is still bindable. Do not reuse that session's cache.
func resetPhysicalNetwork() {
	physicalNetwork.mu.Lock()
	physicalNetwork.id = 0
	physicalNetwork.expires = time.Time{}
	physicalNetwork.mu.Unlock()
	physicalBindingLogged.Store(false)
}

func bindToPhysicalNetwork(fd int) (int32, error) {
	id, err := selectedPhysicalNetwork()
	if err != nil {
		return 0, err
	}
	code := int32(C.flclash_bind_physical_socket(C.int(fd), C.int32_t(id)))
	if code == 0 {
		return id, nil
	}
	// The network may have changed since it was cached (Wi-Fi to cellular).
	invalidatePhysicalNetwork(id)
	newID, retryErr := selectedPhysicalNetwork()
	if retryErr != nil {
		return 0, retryErr
	}
	code = int32(C.flclash_bind_physical_socket(C.int(fd), C.int32_t(newID)))
	if code != 0 {
		invalidatePhysicalNetwork(newID)
		return 0, physicalBindError{stage: 4, code: code}
	}
	return newID, nil
}

func reportPhysicalBinding(id int32, err error) {
	if err != nil {
		if physicalBindingFailed.CompareAndSwap(false, true) {
			var bindError physicalBindError
			if errors.As(err, &bindError) {
				C.flclash_log_socket_bind_failure(C.int(bindError.stage), C.int(bindError.code))
			} else {
				var errno syscall.Errno
				if errors.As(err, &errno) {
					C.flclash_log_socket_bind_failure(5, C.int(errno))
				} else {
					C.flclash_log_socket_bind_failure(5, 0)
				}
			}
		}
		return
	}
	if physicalBindingFailed.Swap(false) || physicalBindingLogged.CompareAndSwap(false, true) {
		C.flclash_log_socket_bind_ready(C.int(id))
	}
}

func init() {
	dialer.DefaultSocketHook = func(network, address string, conn syscall.RawConn) error {
		if !needsPhysicalBinding(network, address) {
			return nil
		}
		var bindErr error
		var id int32
		if err := conn.Control(func(fd uintptr) {
			id, bindErr = bindToPhysicalNetwork(int(fd))
		}); err != nil {
			bindErr = err
		}
		reportPhysicalBinding(id, bindErr)
		return bindErr
	}
}
