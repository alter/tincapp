#!/usr/bin/env bash
# Tinc Mesh VPN: Container entrypoint for reproducible APK builds.
#
# Behaviour:
#   - If the project already ships a keystore.properties (real release key),
#     build with that and do not touch the keystore directory.
#   - Otherwise, generate a self-signed RSA-4096 keystore in /keystore on the
#     first run and reuse it on subsequent runs so the signing identity stays
#     stable across rebuilds.
#   - Resulting APKs are copied to /output.

set -euo pipefail

SOURCE_DIR="${SOURCE_DIR:-/workspace}"
KEYSTORE_DIR="${KEYSTORE_DIR:-/keystore}"
OUTPUT_DIR="${OUTPUT_DIR:-/output}"

KEYSTORE_FILE="${KEYSTORE_DIR}/release.jks"
KEYSTORE_PASS_FILE="${KEYSTORE_DIR}/release.password"
KEYSTORE_DNAME="${KEYSTORE_DNAME:-CN=tincapp self-signed, O=Local Build, C=ZZ}"
KEY_ALIAS="${KEY_ALIAS:-tincapp}"
GENERATED_PROPS="${SOURCE_DIR}/keystore.properties"
GENERATED_BY_THIS_RUN=0

trap 'cleanup' EXIT
cleanup() {
  if [[ "${GENERATED_BY_THIS_RUN}" -eq 1 && -f "${GENERATED_PROPS}" ]]; then
    rm -f "${GENERATED_PROPS}"
  fi
}

if [[ ! -d "${SOURCE_DIR}" ]]; then
  echo "ERROR: source directory ${SOURCE_DIR} is not mounted." >&2
  exit 1
fi

mkdir -p "${OUTPUT_DIR}"

if [[ -f "${GENERATED_PROPS}" ]]; then
  echo "==> Using existing keystore.properties from the project tree."
else
  mkdir -p "${KEYSTORE_DIR}"

  if [[ ! -f "${KEYSTORE_FILE}" ]]; then
    echo "==> No release key found. Generating a self-signed keystore at ${KEYSTORE_FILE}"
    PASS="$(head -c 24 /dev/urandom | base64 | tr -d '/+=' | head -c 32)"
    printf '%s' "${PASS}" > "${KEYSTORE_PASS_FILE}"
    chmod 600 "${KEYSTORE_PASS_FILE}"
    keytool -genkeypair -noprompt \
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

cd "${SOURCE_DIR}"

if [[ ! -x ./gradlew ]]; then
  chmod +x ./gradlew
fi

# When the user bind-mounts a host directory at ${GRADLE_USER_HOME} for
# Maven dependency caching, the mount hides the Gradle distribution that
# was baked into the image. Seed the mount from the prebake on first run
# so the wrapper does not re-download gradle-*-all.zip every time.
GRADLE_PREBAKE="${GRADLE_PREBAKE:-/opt/gradle-prebake}"
GRADLE_USER_HOME="${GRADLE_USER_HOME:-/gradle-cache}"
if [[ -d "${GRADLE_PREBAKE}" && ! -d "${GRADLE_USER_HOME}/wrapper/dists" ]]; then
  echo "==> Seeding ${GRADLE_USER_HOME} from ${GRADLE_PREBAKE}"
  mkdir -p "${GRADLE_USER_HOME}"
  cp -an "${GRADLE_PREBAKE}/." "${GRADLE_USER_HOME}/"
fi
export GRADLE_USER_HOME

GRADLE_TASKS=("$@")
if [[ "${#GRADLE_TASKS[@]}" -eq 0 ]]; then
  GRADLE_TASKS=("assembleRelease")
fi

# Bump default 30s HTTP timeouts so slow Maven Central reads do not abort
# the build on flaky networks.
GRADLE_OPTS_LIST=(
  "-Dorg.gradle.internal.http.connectionTimeout=180000"
  "-Dorg.gradle.internal.http.socketTimeout=180000"
)

# AGP downloads its own AAPT2 from Maven (linux artifact = x86_64 only).
# On linux/arm64 hosts that fails outright; even on amd64 hosts using
# emulation it crashes inside the dynamic linker. Force AGP to use the
# AAPT2 shipped by the SDK build-tools, which sdkmanager has installed
# matching the host architecture.
SDK_AAPT2="${ANDROID_HOME}/build-tools/${ANDROID_BUILD_TOOLS_VERSION:-35.0.0}/aapt2"
if [[ -x "${SDK_AAPT2}" ]]; then
  GRADLE_OPTS_LIST+=("-Pandroid.aapt2FromMavenOverride=${SDK_AAPT2}")
fi

echo "==> Running: ./gradlew --no-daemon ${GRADLE_OPTS_LIST[*]} ${GRADLE_TASKS[*]}"
./gradlew --no-daemon "${GRADLE_OPTS_LIST[@]}" "${GRADLE_TASKS[@]}"

echo "==> Collecting APKs into ${OUTPUT_DIR}"
shopt -s globstar nullglob
copied=0
for apk in app/build/outputs/apk/**/*.apk; do
  cp -v "${apk}" "${OUTPUT_DIR}/"
  copied=$((copied + 1))
done

if [[ "${copied}" -eq 0 ]]; then
  echo "ERROR: no APK was produced." >&2
  exit 1
fi

echo "==> Done. ${copied} APK(s) available in ${OUTPUT_DIR}."
