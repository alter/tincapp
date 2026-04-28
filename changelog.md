# Changelog

This file lists notable changes that have been made to the application on each release.
Releases are tracked and referred to using git tags.

## v0.43 -- 2026-04-28

### Features
- optional QUIC transport per network via the [link0ln/tinc-quic][quic-fork]
  fork. Set `TransportMode = quic` in `tinc.conf` and the app launches
  `libtincd-quic.so` (built with MsQuic + quictls) instead of the classic
  daemon. Classic and QUIC networks coexist and are dispatched
  per-network from the network's own `tinc.conf`. Detects an unsupported
  OS (QUIC requires Android 14+) or a build that does not bundle the
  QUIC binaries and surfaces a localised error before exec.
- read the tinc-quic-style `VPNAddress = X.Y.Z.W/N` directive from
  `tinc.conf` as a fallback for `network.conf`'s `Address` field, so a
  fork-style "everything in tinc.conf" layout drives the Android VPN
  builder without needing an Android-only file.
- import a network configuration from a zip archive
  (configure → tools → "Import network from archive"). Refuses archives
  whose `*.conf` or `invitation-data` contain `${...}` lookup
  expressions, neutralising CVE-2022-33980-class RCE through the fork's
  config parser.

### Security
- drop the `makePublic` helper that left fresh tinc keys
  world-readable / world-writable on disk; new networks are explicitly
  owner-only.
- exclude `networks/` from cloud backup and device-to-device transfer
  in both `full-backup-content` and `data-extraction-rules`, regardless
  of `requireFlags`. Private tinc keys never leave the device.
- prompt for confirmation before acting on an external
  `org.pacien.tincapp.intent.action.CONNECT` / `tinc://` intent, and
  force the status screen open afterwards. Stops malicious apps from
  silently switching the user onto a different already-configured tinc
  network once VPN permission is granted.
- disable variable interpolation on every `commons-configuration2`
  parser entry point as defence in depth.
- bump BouncyCastle from end-of-life `bcpkix-jdk15on:1.67` to
  `bcpkix-jdk18on:1.78`, `commons-beanutils` 1.9.3 → 1.9.4,
  `slf4j-api` 1.7.30 → 1.7.36.

### Build / packaging
- new local APK builders so contributors can produce a signed APK
  without configuring a release keystore by hand:
  - `./build-mac.sh` for Apple Silicon Macs (native, uses the darwin
    NDK).
  - `docker build -f Dockerfile && docker run ... tincapp-builder` for
    x86_64 Linux hosts and CI.
  - both generate a self-signed RSA-4096 keystore in `./keystore/` on
    the first run and reuse it forever after, so rebuilt APKs install
    as upgrades over the previous one.
- new tinc-quic native pipeline: `./build-quic-mac.sh` (Apple Silicon
  native) and `docker/Dockerfile.quic-binaries` (x86_64 Linux). Both
  cross-compile [quictls][quictls] → [MsQuic][msquic] → tinc-quic for
  all four Android ABIs and drop `libtincd-quic.so` /
  `libtinc-quic.so` / `libmsquic.so` straight into
  `app/src/main/jniLibs/<abi>/`.
- replace deprecated `androidx.lifecycle:lifecycle-extensions:2.2.0`
  with `lifecycle-livedata:2.8.7` + `lifecycle-viewmodel:2.8.7`.
- bump `buildToolsVersion` to 35.0.0 (first version with linux-aarch64
  archives) so CI can build natively on arm64 Linux.
- decouple the release signing config from the Google Play Publisher
  API key in `app/build.gradle`. The `triplet.play` plugin is now
  applied conditionally so a partial `keystore.properties` (signing
  only) builds cleanly.

### Internal cleanup
- clear deprecated-API warnings (`Handler()`, `ReversedLinesFileReader`,
  `ViewModelProviders.of()`).
- migrate the new import dialog to `ActivityResultContracts`.

[quic-fork]: https://github.com/link0ln/tinc-quic
[quictls]: https://github.com/quictls/openssl
[msquic]: https://github.com/microsoft/msquic

## v0.42 -- 2024-10-04
- fix automatic config dir migration issue

## v0.41 -- 2024-09-18
- rename app from "Tinc App" to "Tinc Mesh VPN" (more descriptive)
- make config and logs dirs accessible via the system's built-in file manager
- move configuration and log directories back to internal private storage

## v0.40 -- 2024-08-31
- update Android SDK target API to 34 (Android 14)
- add monochrome app icon

## v0.39 -- 2024-01-20
- fix permissions for newly created or joined network host and key files

## v0.38 -- 2023-07-30
- make configuration files and logs accessible in the user-accessible storage
  (in USB storage mode). The embedded FTP server has been removed
- display errors on the home screen instead of through the system notifications
  (as recommended-required for Android 13, API 33)
- fix app crash on fast tap in network selection and configuration screens
- include the configuration with its private keys in encrypted device backups
- update LibreSSL to 3.7.3

## v0.37 -- 2023-01-30
- add russian translation (contributed by exclued)

## v0.36 -- 2023-01-09
- inherit metered network restriction from underlying link (android 10+)

## v0.35 -- 2023-01-06
- fix app crash when connecting or enabling FTP server (android 12+)

## v0.34 - 2023-01-02
- add prominent warning at the top of the network list (Google Play requirement)
- update LibreSSL to 3.6.1
- update Android SDK target API to 32

## v0.33 - 2021-07-12
- update tinc to 1.1-pre18
- update LibreSSL to 3.3.3

## v0.32 - 2020-12-17
- Android 11 compatibility: expose configuration and log files through an embedded FTP server
- improve security by moving the configuration, keys and logs to a private location
- update tinc to latest snapshot (1.1-3ee0d5d)
- update LibreSSL to 3.2.2

## v0.31 - 2020-09-16
- fix app crash when external cache directory isn't available (for compatibility with Android 11)
- patch tinc for fortified libc checks (for compatibility with Android NDK r21)
- update LibreSSL to 3.1.4

## v0.30 - 2020-01-20
- fix missing system logger dependency on Android 10
- revert back to target API 28 to fix daemon not starting on Android 5

## v0.29 - 2020-01-20
- fix Android 10 compatibility issue and set target API to 29
- update tinc to patched snapshot (1.1-f522393)
- update LibreSSL to 3.0.2

## v0.28 - 2019-09-15
- fix daemon startup on Android 10
- notify user of missing VPN permission

## v0.27 - 2019-06-14
- fix R8 optimisation that made the app unable to load its libraries

## v0.26 - 2019-06-13
- make tinc automatic reconnection on network change optional with new configuration key (`ReconnectOnNetworkChange`)
- update LibreSSL to 2.9.2

## v0.25 - 2019-03-25
- implement a workaround for broken file permissions on Android-x86
- kill any remnant tinc daemon when starting a new connection
- minor UI improvements

## v0.24 - 2019-02-18
- update tinc to latest snapshot (1.1-017a7fb), fixing UDP spam
- update LibreSSL to 2.8.3
- new app icon

## v0.23 - 2018-10-08
- update tinc to 1.1pre17 (security update: CVE-2018-16737, CVE-2018-16738, CVE-2018-16758)

## v0.22 - 2018-09-27
- improve stability

## v0.21 - 2018-09-26
- force re-connection on network change
- improve stability

## v0.20 - 2018-09-09
- update existing translations
- improve assisted error reporting
- minor UI improvements

## v0.19 - 2018-08-22
- add a subnet list view
- show node reachability status
- other minor UI improvements
- embed a QR-code scanner

## v0.18 - 2018-08-07
- add support for always-on VPN
- error handling and stability improvements
- minor UI and branding improvements

## v0.17 - 2018-06-25
- update tinc to 1.1pre16
- update LibreSSL to 2.7.4
- update BCPKIX lib to 1.59

## v0.16 - 2018-06-11
- better QR-code integration
- update LibreSSL to 2.7.3
- reduce APK size

## v0.15 - 2018-05-26
- drop support for the deprecated armeabi architecture
- better error handling and reporting
- minor UI improvements

## v0.14 - 2018-04-23
- update LibreSSL to 2.7.2
- minor UI improvements

## v0.13 - 2018-03-31
- add assisted bug report feature
- minor UI improvements

## v0.12 - 2018-03-14
- better error handling
- minor UI improvements

## v0.11 - 2018-03-04
- generate a sub network configuration file when bootstrapping
- add a log viewer screen
- fix private key encryption on release versions

## v0.10 - 2018-02-24
- better error reporting
- minor UI improvements

## v0.9 - 2018-02-16
- better daemon state handling and reporting
- minor UI improvements

## v0.8 - 2018-02-10
- add Chinese translation
- update tinc to latest pre-release (1.1pre15)
- update LibreSSL to 2.6.4
- minor UI improvements
- handle unavailable external storage

## v0.7 - 2017-09-07
- add support for private key encryption using a password
- minor UI improvements
- error handling and stability improvements

## v0.6 - 2017-08-24
- update tinc to latest snapshot (1.1-92fdabc)
- add an option to join a tinc network by scanning a QR-code
- minor UI improvements

## v0.5 - 2017-08-22
- improve stability
- do not request useless permissions

## v0.4 - 2017-08-18
- update tinc to latest snapshot (1.1-7c22391)
- expose intents to allow connection and disconnection from other apps
- minor UI improvements

## v0.3 - 2017-08-03
- update tinc to latest snapshot (1.1-acefa66)
- update LibreSSL to 2.5.5
- add a connection status screen
- add an option to join a tinc network via the UI
- make external calls asynchronous

## v0.2 - 2017-07-03
- add Norwegian Bokmål and Japanese translations
- add a list of confgured tinc networks in the UI
- remove support for the MIPS architecture
- remove support for alternate configuration path
- port to Kotlin

## v0.1-preview - 2017-05-05
- basic working proof-of-concept using a patched tinc 1.1pre15
