// geofence_kit — public API.
//
// DELIBERATELY MINIMAL. The engine ships with a single hand-tuned
// "Quick & Efficient" profile and the public surface is:
//
//   Geofence(...)                 — the fence itself
//   GeofenceKit.instance.start(...)  — registers on every app boot
//                                    (showDebugNotification: native debug notes)
//   GeofenceKit.instance.onEvent     — live stream (foreground/background)
//   GeofenceKit.instance.enableHeadlessTask(...)  — Dart code even while
//                                    the app is TERMINATED (Android)
//   GeofenceKit.instance.stop() / engineStateSnapshot() / flushOutbox()
//   GeofenceEvent                  — the enriched event contract
//   LegacyGeofenceEvent            — legacy/geofence_event.dart (the
//                                    minimal five-field event shape)
//
// Notifications: the plugin posts NO user-facing notifications.
// Its only notification surface is the DEBUG story — a native
// "captured NATIVELY" note per committed transition, gated by
// `start(showDebugNotification: true)` (default false). For your own
// event notifications use any notification package (e.g.
// flutter_local_notifications) from `onEvent` / your headless task —
// the plugin exposes no notification config or note-posting API.
//
// Advanced tuning (hysteresis, confirmation counts, heartbeat cadence,
// proximity margins…) may be exposed in a later release once the defaults
// are proven in the field.
//
// Canonical public API — lib/ is the single copy.

// NOTE: `export` alone does NOT bring a name into this file's own scope —
// the facade imports the names its own code uses AND re-exports them.

import 'dart:async';
import 'dart:core';
import 'dart:math' as math;

import 'src/adaptive_config.dart' show AdaptiveEngineConfig, GeofenceEvent;
import 'src/method_channel_geofence_kit.dart' show MethodChannelGeofenceKit;

export 'legacy/geofence_event.dart' show LegacyGeofenceEvent;
export 'src/adaptive_config.dart' show GeofenceEvent, GeofenceEventSource;

/// A geofence: a circle, or a polygon when [vertices] has ≥ 3 points.
///
/// Radius guidance: 100 m+ fences track best on every device (OS geofence
/// floors, GNSS urban accuracy). Smaller fences still work — the engine
/// registers them with the OS at an inflated 100 m "wake-up" radius
/// and decides the true boundary from its own fix stream.
///
/// Polygons: pass [vertices] as `[lat, lng]` pairs in order (the
/// ring is closed automatically). [latitude]/[longitude] then carry the
/// polygon centroid and [radiusMeters] may be omitted — the bounding-circle
/// radius around the centroid is computed for you (it drives proximity
/// tiering and the OS wake-up circle; containment is decided by ray-casting
/// on [vertices]).
///
/// Per-fence notify flags: suppress individual transition kinds
/// (state still tracks internally for correctness). [extras] rides on
/// every event emitted for this fence.
class Geofence {
  /// Stable identifier (also used by the OS geofence tripwire).
  final String id;

  /// Center latitude in degrees (polygon centroid when [vertices] is set).
  final double latitude;

  /// Center longitude in degrees (polygon centroid when [vertices] is set).
  final double longitude;

  /// Radius in meters for circles (0 < r ≤ 100_000). Optional for
  /// polygons — the bounding-circle radius is computed when omitted.
  final double? radiusMeters;

  /// Polygon vertices as `[lat, lng]` pairs; ≥ 3 entries makes this fence
  /// a polygon (ray-cast containment decides ENTER/EXIT).
  final List<List<double>>? vertices;

  /// Emit ENTER events for this fence (default `true`).
  final bool notifyOnEnter;

  /// Emit EXIT events for this fence (default `true`).
  final bool notifyOnExit;

  /// Emit DWELL events for this fence (default `true`; DWELL itself is
  /// enabled per-start via `GeofenceKit.start(dwell:)`).
  final bool notifyOnDwell;

  /// Arbitrary metadata carried onto every event for this fence.
  final Map<String, Object?>? extras;

  /// Creates a fence — see the class docs for the circle / polygon
  /// shapes and per-field guidance; [isValid] reports structural
  /// problems and [effectiveRadiusMeters] the radius the engine will
  /// run with.
  const Geofence({
    required this.id,
    required this.latitude,
    required this.longitude,
    this.radiusMeters,
    this.vertices,
    this.notifyOnEnter = true,
    this.notifyOnExit = true,
    this.notifyOnDwell = true,
    this.extras,
  });

  /// `true` when this fence is polygon-decided (≥ 3 vertices).
  bool get isPolygon => vertices != null && vertices!.length >= 3;

  /// Structural validity (mirrors the native engines' check).
  bool get isValid {
    if (id.isEmpty || id.length > 256) return false;
    if (latitude < -90 ||
        latitude > 90 ||
        longitude < -180 ||
        longitude > 180) {
      return false;
    }
    if (isPolygon) {
      return vertices!.every((v) =>
          v.length >= 2 &&
          v[0] >= -90 &&
          v[0] <= 90 &&
          v[1] >= -180 &&
          v[1] <= 180);
    }
    final r = radiusMeters;
    return r != null && r > 0 && r <= 100000;
  }

  /// Resolved radius: the supplied [radiusMeters], or the computed
  /// bounding-circle radius for polygons. `-1` when unresolvable.
  double get effectiveRadiusMeters {
    final r = radiusMeters;
    if (r != null) return r;
    if (!isPolygon) return -1;
    var maxDistance = 0.0;
    for (final v in vertices!) {
      if (v.length < 2) continue;
      final d = _haversineMeters(latitude, longitude, v[0], v[1]);
      if (d > maxDistance) maxDistance = d;
    }
    return maxDistance <= 0 ? -1 : maxDistance;
  }

  /// Wire map for the method channel: identity, position, the resolved
  /// radius (present only when resolvable), polygon [vertices] when set,
  /// only the non-default notify flags, and [extras] when supplied.
  Map<String, Object?> toMap() {
    final r = effectiveRadiusMeters;
    return <String, Object?>{
      'id': id,
      'latitude': latitude,
      'longitude': longitude,
      if (r > 0) 'radiusMeters': r,
      if (isPolygon) 'vertices': vertices,
      if (!notifyOnEnter) 'notifyOnEnter': false,
      if (!notifyOnExit) 'notifyOnExit': false,
      if (!notifyOnDwell) 'notifyOnDwell': false,
      if (extras != null) 'extras': extras,
    };
  }
}

/// Great-circle distance in meters (mean-earth radius 6_371_008.8 —
/// parity with both native engines).
double _haversineMeters(double lat1, double lng1, double lat2, double lng2) {
  const radius = 6371008.8;
  const degToRad = math.pi / 180.0;
  final phi1 = lat1 * degToRad;
  final phi2 = lat2 * degToRad;
  final dPhi = (lat2 - lat1) * degToRad;
  final dLambda = (lng2 - lng1) * degToRad;
  final sinPhi = math.sin(dPhi / 2);
  final sinLambda = math.sin(dLambda / 2);
  final a =
      sinPhi * sinPhi + math.cos(phi1) * math.cos(phi2) * sinLambda * sinLambda;
  final c = 2 * math.atan2(math.sqrt(a), math.sqrt(math.max(0.0, 1.0 - a)));
  return radius * c;
}

/// Result of a successful engine start.
class StartResult {
  /// Whether the engine accepted the fences.
  final bool started;

  /// Number of structurally valid fences registered.
  final int fencesRegistered;

  /// Effective motion-aware engine ("adaptive") — always true.
  final bool adaptiveEngine;

  /// Refusal reason when [started] is `false` — e.g. `LOCATION_DENIED`,
  /// `INVALID_FENCE`, `PERMISSION_TIMEOUT`. Empty/`null` on success.
  final String? message;

  /// Whether the background-location grant (Android's "Allow all the
  /// time" / ACCESS_BACKGROUND_LOCATION) is in effect.
  ///
  /// When `false` the engine still tracks while the app is
  /// FOREGROUND-visible, but the moment it leaves the foreground the OS
  /// silently stops delivering location fixes AND geofence transitions —
  /// no ENTER/DWELL/EXIT will fire while backgrounded or terminated.
  /// Surface this loudly (an in-app warning + a button calling
  /// [GeofenceKit.openAppSettings]; Android 11+ only grants "Allow all
  /// the time" from the system Settings page). Defaults to `true` when a
  /// platform does not report it.
  final bool backgroundLocationGranted;

  /// Creates a start outcome — normally produced by
  /// `GeofenceKit.start`, not constructed by hand.
  const StartResult({
    required this.started,
    required this.fencesRegistered,
    required this.adaptiveEngine,
    this.message,
    this.backgroundLocationGranted = true,
  });
}

/// The application's headless callback: invoked per
/// [GeofenceEvent] inside a headless background isolate while the app is
/// terminated (Android). Async callbacks are awaited — return a `Future`
/// for I/O work; the task's granted window is short (~10 s quiet, 30 s hard).
typedef GeofenceHeadlessTask = FutureOr<void> Function(GeofenceEvent event);

/// The single public entry point.
///
/// The engine runs the hand-tuned "Quick & Efficient" profile:
/// accuracy-gated fixes (max(25 m, R/2)), hysteresis band 0.85 R/1.15 R,
/// auto confirmation counts (1 when R < 75 m else 2), velocity fast-path
/// EXIT above 8 m/s, motion-aware presets (STILL-latch 180 s), heartbeat
/// 300 s, dwell reconciliation across process death, sensor-fusion motion
/// fallback (accelerometer/gyroscope/magnetometer) when activity
/// recognition is unavailable, and provider fallback GMS → HMS → platform.
abstract class GeofenceKit {
  static GeofenceKit? _instance;

  /// Process-wide instance. Lazily defaults to the method-channel
  /// implementation; a custom implementation (tests) can replace it via
  /// [instance=] before first access.
  static GeofenceKit get instance => _instance ??= MethodChannelGeofenceKit();

  /// Plugin glue (or tests) assign their implementation instance here.
  static set instance(GeofenceKit impl) => _instance = impl;

  /// Register [fences] and begin tracking. Call on every app boot (app
  /// launch AND after device reboot — the engine re-registers from
  /// persisted state automatically on Android; on iOS region monitoring
  /// persists at the OS level and the app relaunch reconciles).
  ///
  /// [dwell]: emit DWELL once the device has stayed INSIDE this long.
  /// `null` (default) disables DWELL. Dwell survives process death.
  ///
  /// [showDebugNotification] (default `false`): the plugin's ONLY
  /// notification surface — a native `"app name · ENTER · fenceId"
  /// / "captured NATIVELY (app …)" debug note posted the moment the engine
  /// commits a transition, in EVERY app state (foreground, background,
  /// terminated). It exists so the delivery chain can be verified in the
  /// field; production apps leave it off and surface events their own way
  /// (any notification package, from `onEvent` or a headless task).
  ///
  /// Repeated calls replace the registered fence set (full re-register).
  Future<StartResult> start({
    required List<Geofence> fences,
    Duration? dwell,
    bool showDebugNotification = false,
  });

  /// Live geofence event stream (foreground and background while the
  /// process is alive; terminated-state events replay from the outbox on
  /// next launch and always surface as local notifications).
  Stream<GeofenceEvent> get onEvent;

  /// Stop tracking and clear the session.
  Future<void> stop();

  /// Debug observability (preset/tier/motion/provider/beats…). May return
  /// an empty map when the engine is not running.
  Future<Map<String, Object?>> engineStateSnapshot();

  /// Drain any events buffered while the app was terminated. Called
  /// automatically on start; exposed for manual pulls.
  Future<void> flushOutbox();

  /// Runtime permission state, platform-normalized:
  /// `{ platform, location, locationBackground, motion, notifications }` —
  /// booleans; `locationBackground` is Android's ACCESS_BACKGROUND_LOCATION
  /// ("Allow all the time") or iOS's Always authorization.
  Future<Map<String, Object?>> permissionStatus();

  /// Deep-link to this app's system settings page — for the
  /// background-location upgrade (Android 11+ offers no dialog for
  /// "Allow all the time"; iOS Always upgrade) and Motion & Fitness fixes.
  Future<void> openAppSettings();

  /// OEM reliability walk-through (Android-only; iOS returns
  /// `{supported: false, …}`): raises the battery-optimization exemption
  /// dialog (once), opens the manufacturer's autostart screen for
  /// Xiaomi/Redmi/POCO, Huawei/Honor, Oppo/Realme, Vivo/iQOO and Letv
  /// devices (once), and falls back to the app-details screen. Call after
  /// `start` resolves, ideally once per install. The returned map describes
  /// what was shown (`brand`, `batteryDialogShown`,
  /// `autostartScreenOpened`, `appDetailsOpened`, …).
  Future<Map<String, Object?>> requestOemAutostart();

  /// Run Dart code even while the app is TERMINATED (Android). The classic
  /// two-handle pattern, built ON TOP of the durable outbox: when a
  /// transition fires with the Flutter UI process
  /// absent, the plugin spawns a headless background FlutterEngine, this
  /// facade's internal bootstrap runs in that isolate, drains the outbox +
  /// live buffer through the SAME `onEvent` machinery (dedup + ack), and
  /// invokes [task] per event — immediately, in the terminated state, with
  /// the full [GeofenceEvent] payload.
  ///
  /// Requirements on [task]: a **top-level or static function**, annotated
  /// `@pragma('vm:entry-point')` (the background isolate resolves it from
  /// a native handle; closures and instance methods cannot cross isolates).
  /// Register once per process, before/after `start` — order does not matter
  /// (the registration is persisted natively and survives reboots).
  ///
  /// **The delivery guarantee is unchanged**: every event is a durable
  /// outbox row first. If the spawn fails (aggressive OEM, stale handle
  /// after an app update, crashed isolate), nothing is lost — the rows
  /// replay at the next app launch flagged `replayed: true`. A successful
  /// headless run acks its rows, so nothing is delivered twice.
  ///
  /// **iOS**: no-op (returns normally) — terminated-state events relaunch
  /// the app there, so [GeofenceKit.onEvent] already delivers them; there
  /// is no headless mechanism to register. Write your logic against
  /// `onEvent` and it works on both platforms.
  Future<void> enableHeadlessTask(GeofenceHeadlessTask task);

  /// Internal (plugin glue): the `adaptive` map for the method channel —
  /// the hand-tuned "Quick & Efficient" engine profile for a [dwell]
  /// duration. Not for app consumption.
  static Map<String, Object?> tunedAdaptiveMap(Duration? dwell) {
    // Deliberately fixed values — see the class docs above. The ONLY knob
    // surfaced publicly is the dwell duration. (Heartbeat emission feeds
    // the native alive-indicator notification; never the public stream.)
    return AdaptiveEngineConfig(
      adaptiveEngine: true,
      loiteringDelayMs: dwell?.inMilliseconds ?? 0,
      emitHeartbeatEvents: true,
    ).toMap();
  }
}
