#!/usr/bin/env bash
# Tinc Mesh VPN: cross-compile tinc-quic + msquic + quictls for Android.
#
# Pipeline per ABI:
#   1. quictls (OpenSSL fork required by msquic), static .a
#   2. msquic linked against quictls, shared .so
#   3. tinc-quic linked against msquic + quictls, executables renamed
#      to lib*.so so they can ship in the APK as native libraries.
#
# Output layout under /output:
#   /output/<abi>/libtincd-quic.so
#   /output/<abi>/libtinc-quic.so
#   /output/<abi>/libmsquic.so

set -euo pipefail

NDK="${ANDROID_NDK:-/opt/android-ndk}"
TOOLS="${NDK}/toolchains/llvm/prebuilt/linux-x86_64/bin"
PATH="${TOOLS}:${PATH}"

CACHE_DIR="${CACHE_DIR:-/cache}"
OUTPUT_DIR="${OUTPUT_DIR:-/output}"
SRC_DIR="${CACHE_DIR}/src"
BUILD_DIR="${CACHE_DIR}/build"

ANDROID_API="${ANDROID_API:-21}"
ABIS="${ABIS:-arm64-v8a armeabi-v7a x86_64 x86}"

QUICTLS_REPO="${QUICTLS_REPO:-https://github.com/quictls/openssl}"
QUICTLS_REF="${QUICTLS_REF:-openssl-3.1.4-quic1}"
MSQUIC_REPO="${MSQUIC_REPO:-https://github.com/microsoft/msquic}"
MSQUIC_REF="${MSQUIC_REF:-main}"
TINC_QUIC_REPO="${TINC_QUIC_REPO:-https://github.com/link0ln/tinc-quic}"
TINC_QUIC_REF="${TINC_QUIC_REF:-main}"

mkdir -p "${SRC_DIR}" "${BUILD_DIR}" "${OUTPUT_DIR}"

# ---------------------------------------------------------------------------
# Source trees
# ---------------------------------------------------------------------------
sync_repo() {
  local url="$1" dest="$2" ref="$3" recursive="${4:-no}"
  if [[ ! -d "${dest}/.git" ]]; then
    echo "==> Cloning ${url} (${ref}) -> ${dest}"
    git clone --depth 1 -b "${ref}" "${url}" "${dest}"
  else
    echo "==> Reusing cached source at ${dest}"
  fi
  if [[ "${recursive}" == "yes" ]]; then
    git -C "${dest}" submodule update --init --recursive --depth 1
  fi
}

sync_repo "${QUICTLS_REPO}"   "${SRC_DIR}/quictls"   "${QUICTLS_REF}"
sync_repo "${MSQUIC_REPO}"    "${SRC_DIR}/msquic"    "${MSQUIC_REF}"    yes
sync_repo "${TINC_QUIC_REPO}" "${SRC_DIR}/tinc-quic" "${TINC_QUIC_REF}" yes

# ---------------------------------------------------------------------------
# Per-ABI build
# ---------------------------------------------------------------------------
abi_to_target() {
  case "$1" in
    arm64-v8a)   OSSL_TARGET=android-arm64    HOST=aarch64-linux-android    ;;
    armeabi-v7a) OSSL_TARGET=android-arm      HOST=armv7a-linux-androideabi ;;
    x86_64)      OSSL_TARGET=android-x86_64   HOST=x86_64-linux-android     ;;
    x86)         OSSL_TARGET=android-x86      HOST=i686-linux-android       ;;
    *) echo "Unknown ABI: $1" >&2; exit 1 ;;
  esac
}

build_quictls() {
  local abi="$1"
  local prefix="${BUILD_DIR}/quictls-${abi}"
  if [[ -f "${prefix}/lib/libssl.a" && -f "${prefix}/lib/libcrypto.a" ]]; then
    echo "==> [${abi}] quictls cached"
    return
  fi
  echo "==> [${abi}] Building quictls"
  abi_to_target "${abi}"
  pushd "${SRC_DIR}/quictls" >/dev/null
  git clean -fdx
  ANDROID_NDK_ROOT="${NDK}" \
    ./Configure "${OSSL_TARGET}" no-shared no-tests no-asm \
      -D__ANDROID_API__="${ANDROID_API}" \
      --prefix="${prefix}"
  make -j"$(nproc)" build_libs
  make install_dev
  popd >/dev/null
}

build_msquic() {
  local abi="$1"
  local build="${BUILD_DIR}/msquic-${abi}"
  local lib
  lib=$(find "${build}" -name 'libmsquic.so' 2>/dev/null | head -1 || true)
  if [[ -n "${lib}" ]]; then
    echo "==> [${abi}] msquic cached at ${lib}"
    return
  fi
  echo "==> [${abi}] Building msquic"
  local quictls="${BUILD_DIR}/quictls-${abi}"
  cmake -B "${build}" -S "${SRC_DIR}/msquic" -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE="${NDK}/build/cmake/android.toolchain.cmake" \
    -DANDROID_ABI="${abi}" \
    -DANDROID_PLATFORM="android-${ANDROID_API}" \
    -DCX_PLATFORM=android \
    -DQUIC_TLS=quictls \
    -DQUIC_BUILD_TOOLS=OFF \
    -DQUIC_BUILD_TEST=OFF \
    -DQUIC_BUILD_PERF=OFF \
    -DBUILD_SHARED_LIBS=ON \
    -DOPENSSL_ROOT_DIR="${quictls}" \
    -DOPENSSL_INCLUDE_DIR="${quictls}/include" \
    -DOPENSSL_CRYPTO_LIBRARY="${quictls}/lib/libcrypto.a" \
    -DOPENSSL_SSL_LIBRARY="${quictls}/lib/libssl.a"
  cmake --build "${build}" -j"$(nproc)"
}

build_tinc_quic() {
  local abi="$1"
  local out="${OUTPUT_DIR}/${abi}"
  if [[ -f "${out}/libtincd-quic.so" && -f "${out}/libtinc-quic.so" && -f "${out}/libmsquic.so" ]]; then
    echo "==> [${abi}] tinc-quic outputs cached, skipping"
    return
  fi
  abi_to_target "${abi}"

  local quictls="${BUILD_DIR}/quictls-${abi}"
  local msquic_build="${BUILD_DIR}/msquic-${abi}"
  local msquic_lib
  msquic_lib=$(find "${msquic_build}" -name 'libmsquic.so' | head -1)
  if [[ -z "${msquic_lib}" ]]; then
    echo "ERROR: libmsquic.so not found under ${msquic_build}" >&2
    exit 1
  fi
  local msquic_libdir
  msquic_libdir=$(dirname "${msquic_lib}")

  local tinc_build="${BUILD_DIR}/tinc-quic-${abi}"
  rm -rf "${tinc_build}"
  mkdir -p "${tinc_build}"

  if [[ ! -f "${SRC_DIR}/tinc-quic/configure" ]]; then
    echo "==> Running autoreconf in tinc-quic"
    (cd "${SRC_DIR}/tinc-quic" && autoreconf -fi)
  fi

  echo "==> [${abi}] Building tinc-quic"
  (
    cd "${tinc_build}"
    CC="${TOOLS}/${HOST}${ANDROID_API}-clang" \
    AR="${TOOLS}/llvm-ar" \
    RANLIB="${TOOLS}/llvm-ranlib" \
    STRIP="${TOOLS}/llvm-strip" \
    CFLAGS="-fPIE -fPIC -I${quictls}/include -I${SRC_DIR}/msquic/src/inc" \
    LDFLAGS="-pie -L${quictls}/lib -L${msquic_libdir} -Wl,-rpath,\$ORIGIN" \
    LIBS="-lmsquic -lssl -lcrypto -llog -ldl -lm" \
      "${SRC_DIR}/tinc-quic/configure" \
        --host="${HOST}" \
        --with-msquic="${msquic_build}" \
        --without-readline --without-curses \
        --disable-lzo \
        ac_cv_func_malloc_0_nonnull=yes \
        ac_cv_func_realloc_0_nonnull=yes
    make -j"$(nproc)"
    "${TOOLS}/llvm-strip" src/tincd src/tinc
  )

  mkdir -p "${out}"
  install -m 0755 "${tinc_build}/src/tincd"     "${out}/libtincd-quic.so"
  install -m 0755 "${tinc_build}/src/tinc"      "${out}/libtinc-quic.so"
  install -m 0755 "${msquic_lib}"               "${out}/libmsquic.so"
  echo "==> [${abi}] Installed:"
  ls -la "${out}"
}

for abi in ${ABIS}; do
  echo "=========================================="
  echo "==> ABI: ${abi}"
  echo "=========================================="
  build_quictls "${abi}"
  build_msquic "${abi}"
  build_tinc_quic "${abi}"
done

echo ""
echo "=========================================="
echo "==> All ABIs done. Output tree:"
echo "=========================================="
find "${OUTPUT_DIR}" -type f -name '*.so' -exec file {} \; | sed "s|${OUTPUT_DIR}/||"
