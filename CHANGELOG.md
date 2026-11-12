# Changelog

## 1.0.1

Changed license to MPL 2.0

## 1.0.0

First release.

### Geofencing

- Motion-aware hybrid geofence engine — accurate `ENTER` / `EXIT` / `DWELL`
  transitions in every app state: foreground, background and terminated.
- Circular fences and polygon fences, freely mixed in one `start()` call —
  both shapes ride the same engine: `DWELL`, per-fence notify flags,
  `extras`, durable delivery and persistence across reboots.
- Polygon geofences: pass `vertices` — ≥ 3 ordered `[lat, lng]` pairs, the
  ring is closed automatically — and `latitude`/`longitude` carry the
  centroid. `radiusMeters` may be omitted: the bounding-circle radius
  around the centroid is computed for you and drives proximity tiering
  and the OS wake-up registration.
- Polygon containment is decided by even-odd ray-casting over the
  vertices on every accuracy-gated fix. No mobile OS offers a native
  polygon region type, so the engine registers the bounding circle with
  the OS as the wake-up tripwire and decides the true polygon boundary
  from its own fix stream.
- Polygons get the full evidence model: confirmation counts, the
  fix-accuracy gate and the velocity fast-path EXIT apply unchanged —
  only the circular hysteresis band does not (containment is binary).
- Sub-100 m fences: registered with the OS at an inflated wake-up radius;
  the true boundary is decided from the engine's own fix stream.
- Provider chain GMS → HMS → platform, with a runtime probe and a safe
  fallback (HMS is opt-in: the host app adds `com.huawei.hms:location`).
- Accuracy-gated evidence model: a fix counts only when its
  horizontal-error circle clears the fence (EXIT); hysteresis band
  0.85 R / 1.15 R; automatic confirmation counts; a velocity fast-path
  EXIT for drive-bys.
- Motion-aware duty cycling: activity-recognition presets, a
  sensor-fusion fallback, a speed heuristic, and a 300 s heartbeat.
- One configuration knob: the dwell duration (`null` disables `DWELL`).

### Event delivery

- Durable outbox: every committed transition is a durable outbox row
  FIRST (one transaction: fence state + event row with a stable event id).
- At-least-once delivery to `onEvent`, deduped by event id; replays
  flagged `replayed: true`. Events survive process death, reboots and
  OEM kills.
- DWELL survives process death (dwell reconciliation across relaunches).
- Terminated-state Dart code on Android via `enableHeadlessTask` — if the
  background spawn ever fails, the rows replay at the next app launch;
  on iOS, terminated events relaunch the app and deliver through
  `onEvent`.

### Platform integration

- Android: a foreground-service tracking engine with a persistent
  liveness notification; automatic re-registration after device reboot;
  a permissions ladder driven by the first `start()` (precise location →
  notifications → "Allow all the time" → motion & fitness); an OEM helper
  for the battery-optimization exemption and manufacturer autostart
  screens.
- iOS: region events relaunch the app; `earlyBootstrap()` wires the
  engine before the Flutter engine spins up; `CLBackgroundActivitySession`
  (iOS 17+) and `CLServiceSession` (iOS 18+) keepers; a
  BGTaskScheduler background-fetch wake with the
  `backgroundFetchWakeMinutes` knob; diff-based region registration and
  state reconciliation on relaunch.
- iOS: UIScene lifecycle ready — the plugin presents no deprecated
  application lifecycle events anymore (Flutter's UISceneDelegate
  migration); the launch-window work (BG task registration) moved from
  the legacy `didFinishLaunchingWithOptions` hook into plugin
  registration. No API change.
- iOS: region-registration failure is best-effort — a failed OS wake
  registration (iOS Simulator: `kCLErrorDomain` 5, no region-monitoring
  support) no longer surfaces `REGION_MONITORING_FAILED` to Dart; it
  logs + records the `registrationError` snapshot field and the session
  continues on engine-side fix-stream evaluation. No API change.

### Dart API

- `GeofenceKit.instance.start({fences, dwell, showDebugNotification})` —
  call on every app boot; repeated calls replace the registered set.
- `onEvent` live stream; `GeofenceEvent` carries a stable `id`, `fenceId`,
  `transition`, full provenance (source / tier / motion / distance /
  accuracy / speed / confidence) and the `replayed` flag.
- `stop()`, `engineStateSnapshot()`, `flushOutbox()`,
  `permissionStatus()`, `openAppSettings()`, `requestOemAutostart()`.
- `Geofence` model with circular or polygon geometry, per-fence notify
  flags (`notifyOnEnter` / `notifyOnExit` / `notifyOnDwell`) and a
  free-form `extras` map.
- Example app under `example/` with a field verification protocol for
  every app state.
