# Tinc Mesh VPN: Reproducible Android APK builder image
# Copyright (C) 2024 Tinc App contributors
#
# Build:
#   docker build -t tincapp-builder .
#
# Run (creates ./build-output/*.apk and persists ./keystore/release.jks):
#   docker run --rm \
#     -v "$(pwd)":/workspace \
#     -v "$(pwd)/keystore":/keystore \
#     -v "$(pwd)/build-output":/output \
#     tincapp-builder

FROM eclipse-temurin:17-jdk-jammy

ARG ANDROID_SDK_ROOT=/opt/android-sdk
# Pin tooling so rebuilds are reproducible.
ARG CMDLINE_TOOLS_VERSION=11076708
ARG ANDROID_PLATFORM=34
ARG ANDROID_BUILD_TOOLS=34.0.0
ARG ANDROID_NDK_VERSION=26.1.10909125
ARG ANDROID_CMAKE_VERSION=3.22.1

ENV ANDROID_HOME=${ANDROID_SDK_ROOT} \
    ANDROID_SDK_ROOT=${ANDROID_SDK_ROOT} \
    GRADLE_USER_HOME=/gradle-cache \
    DEBIAN_FRONTEND=noninteractive

# Native build of bundled tinc/LibreSSL/LZO is autotools-based: keep these tools handy.
RUN apt-get update && apt-get install -y --no-install-recommends \
      curl unzip ca-certificates git python3 \
      build-essential make autoconf automake libtool pkg-config \
      rsync \
    && rm -rf /var/lib/apt/lists/*

RUN mkdir -p ${ANDROID_SDK_ROOT}/cmdline-tools && \
    curl -fsSL "https://dl.google.com/android/repository/commandlinetools-linux-${CMDLINE_TOOLS_VERSION}_latest.zip" \
      -o /tmp/cmdline-tools.zip && \
    unzip -q /tmp/cmdline-tools.zip -d ${ANDROID_SDK_ROOT}/cmdline-tools && \
    mv ${ANDROID_SDK_ROOT}/cmdline-tools/cmdline-tools ${ANDROID_SDK_ROOT}/cmdline-tools/latest && \
    rm /tmp/cmdline-tools.zip

ENV PATH=${PATH}:${ANDROID_SDK_ROOT}/cmdline-tools/latest/bin:${ANDROID_SDK_ROOT}/platform-tools

RUN yes | sdkmanager --licenses >/dev/null && \
    sdkmanager --install \
      "platform-tools" \
      "platforms;android-${ANDROID_PLATFORM}" \
      "build-tools;${ANDROID_BUILD_TOOLS}" \
      "ndk;${ANDROID_NDK_VERSION}" \
      "cmake;${ANDROID_CMAKE_VERSION}" \
    && yes | sdkmanager --licenses >/dev/null

COPY docker/build-apk.sh /usr/local/bin/build-apk
RUN chmod +x /usr/local/bin/build-apk

WORKDIR /workspace
VOLUME ["/workspace", "/keystore", "/output", "/gradle-cache"]

ENTRYPOINT ["/usr/local/bin/build-apk"]
CMD ["assembleRelease"]
