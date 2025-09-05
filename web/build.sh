#!/usr/bin/env bash

set -euo pipefail

DEST=./out/
QEMU_WASM_REPO=qemu-wasm
BUILD_CONTAINER_NAME=build-qemu-wasm-xv6

TMPDIR=$(mktemp -d)
mkdir -p "${DEST}"

cleanup() {
  rm -r "${TMPDIR}"
  docker kill "${BUILD_CONTAINER_NAME}" || true
}
trap cleanup EXIT

if [ ! -d "$QEMU_WASM_REPO" ]; then
  git clone https://github.com/ktock/qemu-wasm
fi

docker build -t buildqemu-tmp - <"${QEMU_WASM_REPO}/Dockerfile"
docker run --rm -d --name "${BUILD_CONTAINER_NAME}" -v "$(realpath $QEMU_WASM_REPO)":/qemu/:rw buildqemu-tmp
EXTRA_CFLAGS="-O3 -g -Wno-error=unused-command-line-argument -matomics -mbulk-memory -DNDEBUG -DG_DISABLE_ASSERT -D_GNU_SOURCE -sASYNCIFY=1 -pthread -sPROXY_TO_PTHREAD=1 -sFORCE_FILESYSTEM -sALLOW_TABLE_GROWTH -sTOTAL_MEMORY=2300MB -sWASM_BIGINT -sMALLOC=mimalloc --js-library=/build/node_modules/xterm-pty/emscripten-pty.js -sEXPORT_ES6=1 -sASYNCIFY_IMPORTS=ffi_call_js"
docker exec "${BUILD_CONTAINER_NAME}" emconfigure /qemu/configure --static --target-list=riscv64-softmmu --cpu=wasm32 --cross-prefix= \
  --without-default-features --enable-system --with-coroutine=fiber --enable-virtfs \
  --extra-cflags="$EXTRA_CFLAGS" --extra-cxxflags="$EXTRA_CFLAGS" --extra-ldflags="-sEXPORTED_RUNTIME_METHODS=getTempRet0,setTempRet0,addFunction,removeFunction,TTY,FS"
docker exec "${BUILD_CONTAINER_NAME}" emmake make -j "$(nproc)" qemu-system-riscv64

mkdir "${TMPDIR}/pack"
cp ../zig-out/bin/kernel "${TMPDIR}/pack"
cp ../fs.img "${TMPDIR}/pack"
docker cp "${TMPDIR}/pack" "${BUILD_CONTAINER_NAME}":/
docker exec "${BUILD_CONTAINER_NAME}" /bin/sh -c "/emsdk/upstream/emscripten/tools/file_packager.py qemu-system-riscv64.data --preload /pack > load.js"

mkdir "${DEST}/xv6"
docker cp "${BUILD_CONTAINER_NAME}":/build/qemu-system-riscv64 "${DEST}/xv6/out.js"
for f in qemu-system-riscv64.wasm qemu-system-riscv64.worker.js qemu-system-riscv64.data load.js; do
  docker cp "${BUILD_CONTAINER_NAME}":/build/${f} "${DEST}/xv6/"
done

cp src/* "${DEST}/xv6/"
