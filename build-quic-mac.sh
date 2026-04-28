#!/usr/bin/env bash
# Tinc Mesh VPN: cross-compile tinc-quic + msquic + quictls for Android,
# natively on a macOS host (Apple Silicon or Intel). Reuses the NDK that
# build-mac.sh already bootstrapped under .tooling/android-sdk/ndk/, so
# nothing emulated, no Docker, no qemu.
#
# Usage:
#   ./build-quic-mac.sh                # all four ABIs into app/src/main/jniLibs/
#   ABIS="arm64-v8a" ./build-quic-mac.sh   # subset for faster iteration
#
# Prerequisites (one-time, via Homebrew):
#   brew install autoconf automake libtool cmake ninja pkg-config

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLING_DIR="${PROJECT_DIR}/.tooling"
CACHE_DIR="${PROJECT_DIR}/.quic-cache"
OUTPUT_DIR="${PROJECT_DIR}/app/src/main/jniLibs"

ANDROID_NDK_VERSION="${ANDROID_NDK_VERSION:-26.1.10909125}"
NDK="${ANDROID_NDK:-${TOOLING_DIR}/android-sdk/ndk/${ANDROID_NDK_VERSION}}"
# API 34 (Android 14): the highest level that NDK r26b ships sysroots
# for. msquic / tinc-quic build against this. Resulting QUIC binaries
# require Android 14+ at runtime - fine for 2025-2026 hardware. The
# classic libtincd.so / libtinc.so remain at the app's minSdk (21).
ANDROID_API="${ANDROID_API:-34}"
ABIS="${ABIS:-arm64-v8a armeabi-v7a x86_64 x86}"

QUICTLS_REPO="${QUICTLS_REPO:-https://github.com/quictls/openssl}"
QUICTLS_REF="${QUICTLS_REF:-openssl-3.1.4-quic1}"
MSQUIC_REPO="${MSQUIC_REPO:-https://github.com/microsoft/msquic}"
MSQUIC_REF="${MSQUIC_REF:-main}"
TINC_QUIC_REPO="${TINC_QUIC_REPO:-https://github.com/link0ln/tinc-quic}"
TINC_QUIC_REF="${TINC_QUIC_REF:-main}"

# ---------------------------------------------------------------------------
# Sanity checks
# ---------------------------------------------------------------------------
if [[ ! -d "${NDK}" ]]; then
  cat >&2 <<EOF
ERROR: Android NDK not found at ${NDK}.
Run ./build-mac.sh once first - it bootstraps the SDK + NDK into
${TOOLING_DIR}/android-sdk/. Or override ANDROID_NDK env to point at
an existing NDK (must contain toolchains/llvm/prebuilt/darwin-x86_64/).
EOF
  exit 1
fi

# NDK ships a Mach-O universal binary at darwin-x86_64 that runs natively
# on both Intel and Apple Silicon Macs.
TOOLS="${NDK}/toolchains/llvm/prebuilt/darwin-x86_64/bin"
if [[ ! -x "${TOOLS}/clang" ]]; then
  echo "ERROR: NDK clang not found at ${TOOLS}/clang" >&2
  exit 1
fi
export PATH="${TOOLS}:${PATH}"
# msquic builds its own bundled quictls during cmake --build, and that
# inner Configure invocation needs ANDROID_NDK_ROOT to find the
# toolchain. Export both names since different scripts pick different ones.
export ANDROID_NDK_ROOT="${NDK}"
export ANDROID_NDK_HOME="${NDK}"

for tool in autoreconf cmake ninja perl pkg-config python3; do
  if ! command -v "${tool}" >/dev/null 2>&1; then
    echo "ERROR: ${tool} not found. Install with: brew install autoconf automake libtool cmake ninja pkg-config" >&2
    exit 1
  fi
done

ncpu() { sysctl -n hw.ncpu 2>/dev/null || echo 4; }

mkdir -p "${CACHE_DIR}/src" "${CACHE_DIR}/build" "${OUTPUT_DIR}"

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

sync_repo "${QUICTLS_REPO}"   "${CACHE_DIR}/src/quictls"   "${QUICTLS_REF}"
sync_repo "${MSQUIC_REPO}"    "${CACHE_DIR}/src/msquic"    "${MSQUIC_REF}"    yes
sync_repo "${TINC_QUIC_REPO}" "${CACHE_DIR}/src/tinc-quic" "${TINC_QUIC_REF}" yes

# ---------------------------------------------------------------------------
# Per-ABI build helpers
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
  local prefix="${CACHE_DIR}/build/quictls-${abi}"
  if [[ -f "${prefix}/lib/libssl.a" && -f "${prefix}/lib/libcrypto.a" ]]; then
    echo "==> [${abi}] quictls cached"
    return
  fi
  echo "==> [${abi}] Building quictls"
  abi_to_target "${abi}"
  pushd "${CACHE_DIR}/src/quictls" >/dev/null
  git clean -fdx
  ANDROID_NDK_ROOT="${NDK}" \
    ./Configure "${OSSL_TARGET}" no-shared no-tests no-asm \
      -D__ANDROID_API__="${ANDROID_API}" \
      --prefix="${prefix}"
  make -j"$(ncpu)" build_libs
  make install_dev
  popd >/dev/null
}

build_msquic() {
  local abi="$1"
  local build="${CACHE_DIR}/build/msquic-${abi}"
  local lib
  lib=$(find "${build}" -name 'libmsquic.so' 2>/dev/null | head -1 || true)
  if [[ -n "${lib}" ]]; then
    echo "==> [${abi}] msquic cached at ${lib}"
    return
  fi
  echo "==> [${abi}] Building msquic"
  local quictls="${CACHE_DIR}/build/quictls-${abi}"
  # Drop any stale CMake cache from a previous failed configure so
  # variable renames (e.g. QUIC_TLS -> QUIC_TLS_LIB) actually take effect.
  rm -rf "${build}"
  # msquic vendor-builds its own quictls submodule, so OPENSSL_*
  # variables are ignored. Our pre-built quictls is kept around purely
  # for tinc-quic (it needs an OpenSSL for SPTPS).
  cmake -B "${build}" -S "${CACHE_DIR}/src/msquic" -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE="${NDK}/build/cmake/android.toolchain.cmake" \
    -DANDROID_ABI="${abi}" \
    -DANDROID_PLATFORM="android-${ANDROID_API}" \
    -DCX_PLATFORM=android \
    -DQUIC_TLS_LIB=quictls \
    -DQUIC_BUILD_TOOLS=OFF \
    -DQUIC_BUILD_TEST=OFF \
    -DQUIC_BUILD_PERF=OFF \
    -DBUILD_SHARED_LIBS=ON
  cmake --build "${build}" -j"$(ncpu)"
}

build_tinc_quic() {
  local abi="$1"
  local out="${OUTPUT_DIR}/${abi}"
  if [[ -f "${out}/libtincd-quic.so" && -f "${out}/libtinc-quic.so" && -f "${out}/libmsquic.so" ]]; then
    echo "==> [${abi}] tinc-quic outputs cached, skipping"
    return
  fi
  abi_to_target "${abi}"

  local quictls="${CACHE_DIR}/build/quictls-${abi}"
  local msquic_build="${CACHE_DIR}/build/msquic-${abi}"
  local msquic_lib
  msquic_lib=$(find "${msquic_build}" -name 'libmsquic.so' | head -1)
  if [[ -z "${msquic_lib}" ]]; then
    echo "ERROR: libmsquic.so not found under ${msquic_build}" >&2
    exit 1
  fi
  local msquic_libdir
  msquic_libdir=$(dirname "${msquic_lib}")

  local tinc_build="${CACHE_DIR}/build/tinc-quic-${abi}"
  rm -rf "${tinc_build}"
  mkdir -p "${tinc_build}"

  # Always regenerate configure: the upstream tarball ships a stale
  # configure that doesn't know fork-specific flags like --with-msquic
  # and may also have an older curses requirement.
  echo "==> Running autoreconf in tinc-quic"
  (cd "${CACHE_DIR}/src/tinc-quic" && autoreconf -fi)

  echo "==> [${abi}] Building tinc-quic"
  (
    cd "${tinc_build}"
    CC="${TOOLS}/${HOST}${ANDROID_API}-clang" \
    AR="${TOOLS}/llvm-ar" \
    RANLIB="${TOOLS}/llvm-ranlib" \
    STRIP="${TOOLS}/llvm-strip" \
    CFLAGS="-fPIE -fPIC -I${quictls}/include -I${CACHE_DIR}/src/msquic/src/inc" \
    LDFLAGS="-pie -L${quictls}/lib -L${msquic_libdir} -Wl,-rpath,\$ORIGIN" \
    LIBS="-lmsquic -lssl -lcrypto -llog -ldl -lm" \
      "${CACHE_DIR}/src/tinc-quic/configure" \
        --host="${HOST}" \
        --with-msquic="${msquic_build}" \
        --without-readline --without-curses \
        --disable-lzo \
        ac_cv_func_malloc_0_nonnull=yes \
        ac_cv_func_realloc_0_nonnull=yes
    make -j"$(ncpu)"
    "${TOOLS}/llvm-strip" src/tincd src/tinc
  )

  mkdir -p "${out}"
  install -m 0755 "${tinc_build}/src/tincd" "${out}/libtincd-quic.so"
  install -m 0755 "${tinc_build}/src/tinc"  "${out}/libtinc-quic.so"
  install -m 0755 "${msquic_lib}"           "${out}/libmsquic.so"
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
find "${OUTPUT_DIR}" -type f -name '*.so' | xargs -I{} sh -c 'printf "%s: " "$1"; file "$1"' _ {}
