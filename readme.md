Tinc Mesh VPN
=============

Android binding and user interface for the tinc mesh VPN daemon which does not
require root privilege.


Help and documentation
----------------------

The complete list of features, the quickstart guides and the user manual can be
found on the project's website: https://tincapp.euxane.net.

Community support is mainly provided through the dedicated Matrix Room and
IRC channel: `#tincapp:pacien.net` and `#tincapp` on `irc.libera.chat`.


Download
--------

Compiled Android packages are available from:

* [F-Droid](https://f-droid.org/packages/org.pacien.tincapp/)
* [Google Play Store](https://play.google.com/store/apps/details?id=org.pacien.tincapp)
* [The project's website](https://tincapp.euxane.net)


Build
-----

There are three supported ways to produce a signed APK. All of them
generate (and then reuse) a self-signed RSA-4096 keystore in
`./keystore/` so successive rebuilds install as upgrades over each
other.

### Apple Silicon Mac (native)

```sh
brew install --cask temurin@17
brew install autoconf automake libtool cmake ninja pkg-config
./build-mac.sh
# APK ends up in ./build-output/app-release.apk
```

`build-mac.sh` bootstraps Android cmdline-tools / SDK / NDK r26b into
`./.tooling/android-sdk/` on first run.

### x86_64 Linux / CI (Docker)

```sh
docker build -t tincapp-builder .
mkdir -p keystore build-output
docker run --rm \
    -v "$(pwd)":/workspace \
    -v "$(pwd)/keystore":/keystore \
    -v "$(pwd)/build-output":/output \
    tincapp-builder
```

The image bundles JDK 17, the Android SDK / NDK r26b and a pre-warmed
Gradle wrapper. Mount `./.gradle-cache` at `/gradle-cache` to keep
Maven dependencies between runs.

### Direct Gradle

If you have the Android SDK / NDK installed and `ANDROID_HOME`
pointing at it:

- `compileSdk` / `targetSdk` 34
- `buildToolsVersion` 35.0.0
- NDK 26.1.10909125
- CMake 3.22.1
- JDK 17
- automake / autoconf for the bundled tinc native build

Then `./gradlew assembleRelease`. Without a `keystore.properties` the
release APK is unsigned; the wrapper scripts above set one up.

### Optional: QUIC transport binaries

The classic tinc daemon is always built. To additionally ship the
[link0ln/tinc-quic][quic-fork] fork (selected per network with
`TransportMode = quic` in `tinc.conf`):

```sh
# Apple Silicon native
./build-quic-mac.sh

# or, on x86_64 Linux
docker build -f docker/Dockerfile.quic-binaries -t tincapp-quic-builder docker/
docker run --rm \
    -v "$(pwd)/app/src/main/jniLibs":/output \
    -v "$(pwd)/.quic-cache":/cache \
    tincapp-quic-builder
```

Each script cross-compiles [quictls][quictls] (an OpenSSL fork
required by MsQuic), [MsQuic][msquic] and tinc-quic for all four
Android ABIs, dropping `libtincd-quic.so` / `libtinc-quic.so` /
`libmsquic.so` straight into `app/src/main/jniLibs/<abi>/`. The
resulting binaries require Android 14+ (Bionic `glob()` API). Without
this step, `assembleRelease` still succeeds and classic networks work
exactly as before.

[quic-fork]: https://github.com/link0ln/tinc-quic
[quictls]: https://github.com/quictls/openssl
[msquic]: https://github.com/microsoft/msquic


License
-------

Copyright (C) 2017-2026 Euxane P. TRAN-GIRARD and contributors (listed in
`contributors.md`).

_Tinc Mesh VPN_ is distributed under the terms of GNU General Public License v3.0,
as detailed in the provided `license.md` file.

Builds of this software embed and make use of the following libraries:

* Kotlin Standard Library, licensed under the Apache v2.0 License
* streamsupport-cfuture, licensed under the GNU General Public License v2.0
* Material Components for Android, licensed under the Apache v2.0 License
* ZXing Android Embedded, licensed under the Apache v2.0 License
* Bouncy Castle PKIX, licensed under the Bouncy Castle License
* SLF4J, licensed under the MIT License
* logback-android, licensed under the GNU Lesser General Public License v2.1
* Apache Commons Configuration, licensed under the Apache v2.0 License
* Apache Commons BeanUtils, licensed under the Apache v2.0 License
* LZO, licensed under the GNU General Public License v2.0
* LibreSSL libcrypto, licensed under the OpenSSL License, ISC License, public
  domain
* tinc, licensed under the GNU General Public License v2.0

Builds that include the QUIC transport additionally embed:

* MsQuic, licensed under the MIT License
* quictls (OpenSSL with QUIC API), licensed under the Apache v2.0 License
* tinc-quic, licensed under the GNU General Public License v2.0
