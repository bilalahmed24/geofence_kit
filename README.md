# Geofence Kit

**Motion-aware hybrid geofence engine for Flutter** — accurate `ENTER` /
`EXIT` / `DWELL` transitions in every app state (foreground, background,
terminated), with a durable delivery contract and a single configuration
knob.


```dart
await GeofenceKit.instance.start(
  fences: [const Geofence(
    id: 'home',
    latitude: 40.782849, longitude: -73.965572, radiusMeters: 250,
  )],
  dwell: const Duration(minutes: 2),
);

GeofenceKit.instance.onEvent.listen((e) {
  print('${e.transition} ${e.fenceId} id=${e.id} replayed=${e.replayed}');
});
```

## What it guarantees

* **Every committed transition is a durable outbox row FIRST** (one
  transaction: fence state + event row with a stable event id). Events are
  delivered to Dart at-least-once — deduped by event id, replays flagged
  `replayed: true` — and survive process death, reboots and OEM kills.
* **DWELL survives process death** (dwell reconciliation across relaunches —
  not a foreground-only software timer).
* **iOS closed-state correctness** — region events relaunch the app;
  `earlyBootstrap()` wires the engine before the Flutter engine spins up.
* **UIScene lifecycle ready** — no deprecated application lifecycle
  events (Flutter's scene migration); classic and scene-based apps behave
  identically, and the launch-window wiring runs at plugin registration.
* **Provider chain GMS → HMS → platform** — Huawei devices without Google
  Play Services geofence through HMS (opt-in: the host app adds
  `com.huawei.hms:location`; the plugin probes at runtime and falls back
  safely when it's absent).
* **Single knob**: the dwell duration. The engine ships one hand-tuned
  "Quick & Efficient" profile (accuracy-gated fixes, hysteresis band
  0.85 R / 1.15 R, auto confirmation counts, velocity fast-path EXIT,
  motion presets, sensor-fusion fallback, 300 s heartbeat).

## Features

* Circular fences and polygons — pass `vertices` (≥ 3 `[lat, lng]` pairs)
  and containment is decided by ray-casting; the bounding circle around
  the centroid is computed for you and drives proximity tiering and the
  OS wake-up registration.
* Sub-100 m fences: registered with the OS at an inflated wake-up radius;
  the true boundary is decided from the engine's own fix stream.
* Per-fence notify flags (`notifyOnEnter` / `notifyOnExit` /
  `notifyOnDwell`) and a free-form `extras` map carried on every event.
* Terminated-state Dart code (Android): `enableHeadlessTask(...)` runs
  your callback per event in a background isolate; on iOS terminated
  events relaunch the app, so `onEvent` delivers them directly.
* Diagnostics built in: `engineStateSnapshot()` (preset / tier / motion /
  provider / beats), `permissionStatus()`, `flushOutbox()`,
  `openAppSettings()`, and an OEM walk-through (`requestOemAutostart()`)
  for battery-optimization exemption and manufacturer autostart screens
  (Xiaomi, Huawei, Oppo, Vivo, …).
* `showDebugNotification: true` on `start` posts a native debug note per
  committed transition in every app state — for field verification.

## Requirements

| | Minimum |
|---|---|
| Flutter / Dart | Flutter 3.19+ / Dart 3.3+ |
| Android | minSdk 23 — Google Play Services optional (HMS is opt-in) |
| iOS | 15.0+ |

Permissions are driven by the first `start()` call: precise location,
notifications (Android 13+), motion & fitness; Android 11+ is handed to
Settings for **Allow all the time**, iOS asks for **Always**.

### iOS Simulator

The simulator does not support region monitoring (`kCLErrorDomain`
error 5). Registration is best-effort: the engine logs it and continues
on its own fix-stream evaluation — events fire while the app is alive,
so use Simulate Location (or a GPX route) to move. Terminated-state
wake needs a real device.

## Install

```yaml
dependencies:
  geofence_kit: ^1.0.0
```

The Dart API layer and the platform glue are included as source, and
both native cores arrive prebuilt — nothing to configure on your side:

* **Android** — the core AAR resolves from **Maven Central**
  (`io.github.bilalahmed24:geofence_kit-core`), like any other Gradle
  dependency.
* **iOS** — the core xcframework is vendored **inside the package** at
  `ios/geofence_kit/geofence_kit.xcframework` and linked by both the
  SwiftPM manifest (`Package.swift`) and the CocoaPods podspec
  (`vendored_frameworks`). No download, no checksum pin, no extra step —
  it works offline from the moment the package lands on disk.

### Optional: HMS on Huawei devices (opt-in)

Google Play Services is optional — on Huawei devices without it, the
engine geofences through **HMS Core** instead. HMS support is
deliberately opt-in: the HMS SDK lives only on Huawei's own Maven
repository, so declaring it inside the plugin would force *every* host
app to configure a repo most of them don't need. To enable it, add two
lines in YOUR app:

1. `android/build.gradle` (the **root** one) — add Huawei's repository:

```groovy
allprojects {
    repositories {
        google()
        mavenCentral()
        maven { url 'https://developer.huawei.com/repo/' } // HMS opt-in
    }
}
```

2. `android/app/build.gradle` — add the HMS location SDK:

```groovy
dependencies {
    implementation "com.huawei.hms:location:6.16.0.302"
}
```

That's all. The engine probes at runtime — HMS present: Huawei devices
geofence through HMS Fused Location; absent: the chain falls back
GMS → platform `LocationManager`, nothing breaks. `example/` ships this
exact setup commented out, ready to uncomment.

## Quick start

```dart
import 'package:geofence_kit/geofence_kit.dart';

await GeofenceKit.instance.start(
  fences: [const Geofence(
    id: 'home',
    latitude: 40.782849, longitude: -73.965572, radiusMeters: 250,
  )],
  dwell: const Duration(minutes: 2),   // optional; null disables DWELL
);

GeofenceKit.instance.onEvent.listen((e) {   // ENTER / EXIT / DWELL
  print('${e.transition} ${e.fenceId} id=${e.id} replayed=${e.replayed}');
});
```

Call `start` on every app boot (launch and device reboot — Android
re-registers automatically; iOS persists at the OS level and reconciles).
Surface the background-location grant (`StartResult.backgroundLocationGranted`,
`openAppSettings()`) — without "Allow all the time" on Android the engine
tracks only while the app is visible.

To run Dart code while the app is terminated (Android), register a
headless task — a top-level or static function, like the callback below:

```dart
@pragma('vm:entry-point')
Future<void> onGeofenceEvent(GeofenceEvent event) async {
  // invoked per event in a background isolate
}

await GeofenceKit.instance.enableHeadlessTask(onGeofenceEvent);
```

A complete runnable app lives in `example/` — an event log with
lifecycle badges, a live engine snapshot panel, and a field verification
protocol for every app state.