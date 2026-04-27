#!/usr/bin/env bash
# Tinc Mesh VPN: native macOS APK builder.
#
# Apple Silicon Macs cannot build the project inside Linux Docker images:
# Google does not publish linux-aarch64 archives for build-tools or NDK,
# and the x86_64 ones crash under both Rosetta and qemu-user. This script
# performs the same workflow as the Dockerfile entrypoint but using the
# darwin-aarch64 / darwin-x86_64 SDK that Google does publish, running
# everything natively on the Mac.
#
# Usage:
#   ./build-mac.sh                  # assembleRelease, APKs in ./build-output
#   ./build-mac.sh assembleDebug    # any other gradle tasks pass through
#
# Requirements:
#   - JDK 17 installed (brew install --cask temurin@17 or similar)
#   - bash, curl, unzip (all stock on macOS)

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLING_DIR="${PROJECT_DIR}/.tooling"
KEYSTORE_DIR="${PROJECT_DIR}/keystore"
OUTPUT_DIR="${PROJECT_DIR}/build-output"

# Keep these in sync with Dockerfile so CI and local builds agree.
ANDROID_PLATFORM=34
ANDROID_BUILD_TOOLS=35.0.0
ANDROID_NDK_VERSION=26.1.10909125
ANDROID_CMAKE_VERSION=3.22.1
CMDLINE_TOOLS_VERSION=11076708

mkdir -p "${TOOLING_DIR}" "${KEYSTORE_DIR}" "${OUTPUT_DIR}"

# ---------------------------------------------------------------------------
# Java 17
# ---------------------------------------------------------------------------
if [[ -z "${JAVA_HOME:-}" || ! -x "${JAVA_HOME}/bin/java" ]]; then
  for candidate in \
    "/opt/homebrew/opt/openjdk@17" \
    "/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home" \
    "/usr/local/opt/openjdk@17" \
    "/Library/Java/JavaVirtualMachines/temurin-17.jdk/Contents/Home" \
    "/Library/Java/JavaVirtualMachines/zulu-17.jdk/Contents/Home" \
    "/Library/Java/JavaVirtualMachines/microsoft-17.jdk/Contents/Home"
  do
    if [[ -x "${candidate}/bin/java" ]]; then
      export JAVA_HOME="${candidate}"
      break
    fi
  done
fi

if [[ -z "${JAVA_HOME:-}" || ! -x "${JAVA_HOME}/bin/java" ]]; then
  cat >&2 <<EOF
ERROR: JDK 17 not found.
Install one of:
  brew install --cask temurin@17
  brew install openjdk@17
or set JAVA_HOME to point at your JDK 17 installation.
EOF
  exit 1
fi
echo "==> Using JDK at ${JAVA_HOME}"
"${JAVA_HOME}/bin/java" -version
export PATH="${JAVA_HOME}/bin:${PATH}"

# ---------------------------------------------------------------------------
# Android SDK
# ---------------------------------------------------------------------------
export ANDROID_HOME="${TOOLING_DIR}/android-sdk"
export ANDROID_SDK_ROOT="${ANDROID_HOME}"
mkdir -p "${ANDROID_HOME}/cmdline-tools"

if [[ ! -x "${ANDROID_HOME}/cmdline-tools/latest/bin/sdkmanager" ]]; then
  CMDLINE_ZIP="commandlinetools-mac-${CMDLINE_TOOLS_VERSION}_latest.zip"
  echo "==> Downloading ${CMDLINE_ZIP}"
  curl -fsSL "https://dl.google.com/android/repository/${CMDLINE_ZIP}" \
    -o "/tmp/${CMDLINE_ZIP}"
  unzip -q "/tmp/${CMDLINE_ZIP}" -d "${ANDROID_HOME}/cmdline-tools"
  rm -rf "${ANDROID_HOME}/cmdline-tools/latest"
  mv "${ANDROID_HOME}/cmdline-tools/cmdline-tools" "${ANDROID_HOME}/cmdline-tools/latest"
  rm "/tmp/${CMDLINE_ZIP}"
fi

export PATH="${ANDROID_HOME}/cmdline-tools/latest/bin:${ANDROID_HOME}/platform-tools:${PATH}"

ANDROID_PACKAGES=(
  "platform-tools"
  "platforms;android-${ANDROID_PLATFORM}"
  "build-tools;${ANDROID_BUILD_TOOLS}"
  "ndk;${ANDROID_NDK_VERSION}"
  "cmake;${ANDROID_CMAKE_VERSION}"
)

echo "==> Ensuring SDK packages are present (sdkmanager is idempotent)"
yes | sdkmanager --licenses >/dev/null
sdkmanager --install "${ANDROID_PACKAGES[@]}"

# ---------------------------------------------------------------------------
# Self-signed release keystore (persistent across rebuilds)
# ---------------------------------------------------------------------------
KEYSTORE_FILE="${KEYSTORE_DIR}/release.jks"
KEYSTORE_PASS_FILE="${KEYSTORE_DIR}/release.password"
KEYSTORE_DNAME="${KEYSTORE_DNAME:-CN=tincapp self-signed, O=Local Build, C=ZZ}"
KEY_ALIAS="${KEY_ALIAS:-tincapp}"
GENERATED_PROPS="${PROJECT_DIR}/keystore.properties"
GENERATED_BY_THIS_RUN=0

cleanup() {
  if [[ "${GENERATED_BY_THIS_RUN}" -eq 1 && -f "${GENERATED_PROPS}" ]]; then
    rm -f "${GENERATED_PROPS}"
  fi
}
trap cleanup EXIT

if [[ -f "${GENERATED_PROPS}" ]]; then
  echo "==> Using existing keystore.properties from the project tree."
else
  if [[ ! -f "${KEYSTORE_FILE}" ]]; then
    echo "==> No release key found. Generating a self-signed keystore at ${KEYSTORE_FILE}"
    PASS="$(head -c 24 /dev/urandom | base64 | tr -d '/+=' | head -c 32)"
    printf '%s' "${PASS}" > "${KEYSTORE_PASS_FILE}"
    chmod 600 "${KEYSTORE_PASS_FILE}"
    "${JAVA_HOME}/bin/keytool" -genkeypair -noprompt \
      -keystore "${KEYSTORE_FILE}" \
      -storetype PKCS12 \
      -storepass "${PASS}" \
      -keypass "${PASS}" \
      -alias "${KEY_ALIAS}" \
      -keyalg RSA -keysize 4096 \
      -validity 10000 \
      -dname "${KEYSTORE_DNAME}"
    chmod 600 "${KEYSTORE_FILE}"
  else
    echo "==> Reusing existing self-signed keystore at ${KEYSTORE_FILE}"
    if [[ ! -f "${KEYSTORE_PASS_FILE}" ]]; then
      echo "ERROR: ${KEYSTORE_FILE} exists but ${KEYSTORE_PASS_FILE} is missing." >&2
      echo "       Restore the password file or delete the keystore to regenerate." >&2
      exit 1
    fi
    PASS="$(cat "${KEYSTORE_PASS_FILE}")"
  fi

  cat > "${GENERATED_PROPS}" <<EOF
storeFile=${KEYSTORE_FILE}
storePassword=${PASS}
keyAlias=${KEY_ALIAS}
keyPassword=${PASS}
EOF
  GENERATED_BY_THIS_RUN=1
fi

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------
cd "${PROJECT_DIR}"
chmod +x ./gradlew

GRADLE_TASKS=("$@")
if [[ "${#GRADLE_TASKS[@]}" -eq 0 ]]; then
  GRADLE_TASKS=("assembleRelease")
fi

GRADLE_OPTS_LIST=(
  "-Dorg.gradle.internal.http.connectionTimeout=180000"
  "-Dorg.gradle.internal.http.socketTimeout=180000"
)

echo "==> Running: ./gradlew --no-daemon ${GRADLE_OPTS_LIST[*]} ${GRADLE_TASKS[*]}"
./gradlew --no-daemon "${GRADLE_OPTS_LIST[@]}" "${GRADLE_TASKS[@]}"

echo "==> Collecting APKs into ${OUTPUT_DIR}"
copied=0
while IFS= read -r apk; do
  cp -v "${apk}" "${OUTPUT_DIR}/"
  copied=$((copied + 1))
done < <(find app/build/outputs/apk -type f -name '*.apk')

if [[ "${copied}" -eq 0 ]]; then
  echo "ERROR: no APK was produced." >&2
  exit 1
fi

echo "==> Done. ${copied} APK(s) available in ${OUTPUT_DIR}."
