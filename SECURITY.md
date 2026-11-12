# Security Policy

## Supported versions

This package is maintained by a single maintainer, so security fixes are only
made on the latest minor line. Please make sure you are on the newest published
release before reporting an issue.

| Version | Supported |
| ------- | --------- |
| 1.x (latest release) | Yes |
| anything older | No |

Fixes are released as patch versions (for example `1.0.0` -> `1.0.1`); the
[CHANGELOG](CHANGELOG.md) notes anything security-relevant. One wrinkle
specific to this plugin: the native cores ship as **prebuilt binaries** — the
Android AAR from Maven Central, the iOS xcframework vendored in-repo. Maven
Central artifacts are immutable, so a fix in a core is always a **new
version**; there is no in-place patching of a published binary.

## Reporting a vulnerability

**Do not open a public GitHub issue, discussion, or pull request for a
suspected security problem.** Please use one of these private channels instead:

1. **GitHub private vulnerability reporting** (preferred): go to the
   repository's **Security** tab and choose **Report a vulnerability**. This
   keeps the report and its discussion private and lets us publish a GitHub
   Security Advisory with credits when the fix ships.
2. **Email**: `bilalahmed24.dev@gmail.com`

Please include, as far as you can:

- a description of the issue and its impact,
- the `geofence_kit` version(s) affected (the `version:` line of the pubspec
  you depend on),
- steps or a minimal snippet to reproduce the problem,
- any suggested mitigation or fix.

You should get an acknowledgment within 72 hours, and we will agree on a fix
and disclosure timeline from there. Please give us a reasonable window to fix
and publish before disclosing publicly; we credit reporters in the changelog
and advisory unless you prefer to stay anonymous.

## Scope

In scope:

- All code in this repository: `lib/`, `android/`, `ios/`, `example/`, and the
  repo's tooling — **and the runtime behavior of the prebuilt cores** (the
  engine binaries the plugin links). For example: anything that could
  transmit location data off the device, persist it outside app-private
  storage, crash applications using the plugin, or let a crafted
  location/region payload compromise a client app.

Out of scope:

- **The underlying location stacks.** Problems inside Google Play Services,
  HMS Core, or the platform `LocationManager` must be reported to Google or
  Huawei through their official security channels — this plugin only consumes
  those SDKs and selects among them at runtime.
- **Vulnerabilities in dependencies** (`play-services-location` and its
  transitive deps, `kotlin-stdlib`). Report those upstream to the owning
  project; we will pick up the patched release through version bumps.
- **Applications built with this plugin.** If the vulnerability is in the
  app's own code (over-broad permission grants, unsafe handling of event
  payloads, etc.), we cannot fix it here, though the posture guidance below
  may help.

## Location data & permission posture

`geofence_kit` is designed so location data never leaves the device:

- **The plugin contains no networking code — on any platform.** The Dart
  layer imports only `dart` core libraries and Flutter; the iOS core (engine +
  glue) makes no network requests; the Android core's compiled classes
  contain no networking classes and its manifest declares no `INTERNET`
  permission at all. There is no telemetry, no analytics, and no crash
  reporting of any kind.
- **Everything stays on-device.** Location fixes are processed in memory;
  committed events are delivered to the app's own Dart code (or its headless
  callback) and persisted in **app-private storage only** — the app-private
  directory on Android, the app sandbox on iOS. Uninstalling the app removes
  every trace.
- **The permission inventory is the feature surface.** Merging the plugin
  adds: location (fine / coarse / background), motion & fitness
  (`ACTIVITY_RECOGNITION`), notifications (Android 13+), boot (re-registering
  fences after a reboot), a `location`-type foreground service, exact alarms
  (the heartbeat), and the battery-optimization exemption request. Nothing
  beyond that list is ever requested; the README documents what each one is
  for.
- **The Android components are non-exported** (the foreground service and all
  engine receivers). The single exported receiver is `BootReceiver`, and it
  handles only the system `BOOT_COMPLETED` broadcast.
- **Binary integrity is verifiable.** The Android core is consumed from Maven
  Central, which publishes per-artifact checksums; the iOS xcframework is
  committed to this repository, so git history is its integrity record. Both
  cores are built by the maintainer from unpublished source; security reports
  are investigated at source and fixes ship as new binary versions.

A code path in this package that transmits data off the device, or persists
it anywhere outside app-private storage, is a vulnerability — please report it
as described above.

For the engine's behavioral guarantees (durable events, at-least-once
delivery), see the README in this repository.
