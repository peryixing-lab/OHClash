#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OHOS_GO=${OHOS_GO:?Set OHOS_GO to the OpenHarmony Go 1.24.5 fork binary}
OHOS_SDK=${OHOS_SDK:-${DEVECO_SDK_HOME:-/Applications/DevEco-Studio.app/Contents/sdk}/default/openharmony}
LLVM="$OHOS_SDK/native/llvm/bin"
OUT="$ROOT/entry/libs/arm64-v8a"
HEADERS="$ROOT/entry/src/main/cpp/prebuilt/arm64-v8a"

if [ ! -x "$OHOS_GO" ] || [ ! -x "$LLVM/aarch64-unknown-linux-ohos-clang" ]; then
  echo 'OpenHarmony Go or SDK clang was not found' >&2
  exit 1
fi

mkdir -p "$OUT"
mkdir -p "$HEADERS"
cd "$ROOT/native/core"
GOOS=openharmony GOARCH=arm64 CGO_ENABLED=1 \
  CC="$LLVM/aarch64-unknown-linux-ohos-clang" \
  CXX="$LLVM/aarch64-unknown-linux-ohos-clang++" \
  CGO_CFLAGS=-ftls-model=global-dynamic \
  "$OHOS_GO" build -trimpath -buildmode=c-shared \
  -tags with_gvisor,no_tailscale,no_zerotier,no_fake_tcp \
  -o "$OUT/libflclash_core.so" .
"$LLVM/llvm-strip" --strip-debug "$OUT/libflclash_core.so"
mv "$OUT/libflclash_core.h" "$HEADERS/flclash_core.h"
echo "Built $OUT/libflclash_core.so"
