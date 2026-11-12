// geofence_kit — adaptive-engine internal config model.
//
// >>> NOT PART OF THE PUBLIC API <<<
// The public surface (lib/geofence_kit.dart — Geofence,
// GeofenceKit.start/stop/onEvent) hides this model entirely: the engine
// runs one hand-tuned "Quick & Efficient" profile.
//
// It remains the method-channel wire format for the `adaptive` map and the
// source of GeofenceEvent (the parsed event payload).
//
// The method-channel `start` call carries `adaptive` through
// `GeofenceKit.tunedAdaptiveMap(dwell)`; `GeofenceEvent.fromMap` parses
// the enriched event payload on the stream (new fields are additive — old
// consumers ignore them).

import 'dart:core';

/// Adaptive-engine configuration.
///
/// All fields are additive; `adaptiveEngine: false` falls back to plain
/// OS-geofence tripwire behavior (no proximity tiers, no motion governor,
/// no accuracy gate).
class AdaptiveEngineConfig {
  /// Master switch: `false` runs the plain OS-geofence tripwire behavior.
  final bool adaptiveEngine;

  /// Proximity margin override in meters.
  /// `null` → auto: `clamp(2·R, 500, 4000)` per fence.
  final int? proximityRadiusM;

  /// Hysteresis fraction `h` in [0, 0.45]: enter at `R·(1−h)` (0.85·R),
  /// exit at `R·(1+h)` (1.15·R) at the default 0.15.
  final double hysteresis;

  /// Gate every fix by horizontal accuracy:
  /// a fix counts only when its accuracy is within `maxFixAccuracyM ?? max(25, R/2)`.
  final bool accuracyGate;

  /// Accuracy gate override in meters. `null` → auto: `max(25, R/2)`.
  final int? maxFixAccuracyM;

  /// Confirmation-count override. `null` → auto: 2 (1 when `R < 75 m`).
  final int? confirmationFixes;

  /// Dwell (loitering) delay in wall-clock ms after INSIDE commits.
  /// DWELL fires once per visit and survives process death (reconciled).
  final int loiteringDelayMs;

  /// Seconds STILL must persist before the engine powers down active
  /// updates (STILL-latch).
  final int stopTimeoutSeconds;

  /// Heartbeat interval in seconds (min 60, default 300).
  /// Android-effective exact-ish alarm; iOS runs an in-process timer
  /// (region/SLC failsafes cover the dormant case).
  final int heartbeatIntervalSeconds;

  /// Synthesize a missed ENTER at reconciliation (device already inside on
  /// start/relaunch). Default `true`.
  final bool initialTriggerEnter;

  /// Synthesize a missed EXIT at reconciliation. Default `true`.
  final bool initialTriggerExit;

  /// Emit heartbeat beats to the engine listener (native observability —
  /// the alive-indicator notification in the plugin glue). Heartbeats are
  /// NOT surfaced on the public event stream. Default `false`.
  final bool emitHeartbeatEvents;

  /// Creates a config — every field has the documented default; the
  /// public facade pins all of them (see `GeofenceKit.tunedAdaptiveMap`)
  /// except [loiteringDelayMs], which carries the `start(dwell:)`
  /// duration.
  const AdaptiveEngineConfig({
    this.adaptiveEngine = true,
    this.proximityRadiusM,
    this.hysteresis = 0.15,
    this.accuracyGate = true,
    this.maxFixAccuracyM,
    this.confirmationFixes,
    this.loiteringDelayMs = 0,
    this.stopTimeoutSeconds = 180,
    this.heartbeatIntervalSeconds = 300,
    this.initialTriggerEnter = true,
    this.initialTriggerExit = true,
    this.emitHeartbeatEvents = false,
  });

  /// Wire map for the method channel (keys are the stable cross-platform
  /// format parsed by both native engines).
  Map<String, Object?> toMap() => <String, Object?>{
        'adaptiveEngine': adaptiveEngine,
        if (proximityRadiusM != null) 'proximityRadiusM': proximityRadiusM,
        'hysteresis': hysteresis,
        'accuracyGate': accuracyGate,
        if (maxFixAccuracyM != null) 'maxFixAccuracyM': maxFixAccuracyM,
        if (confirmationFixes != null) 'confirmationFixes': confirmationFixes,
        'loiteringDelayMs': loiteringDelayMs,
        'stopTimeoutSeconds': stopTimeoutSeconds,
        'heartbeatIntervalSeconds': heartbeatIntervalSeconds,
        'initialTriggerEnter': initialTriggerEnter,
        'initialTriggerExit': initialTriggerExit,
        'emitHeartbeatEvents': emitHeartbeatEvents,
      };

  /// Tolerant parser (round-trips through [toMap]).
  static AdaptiveEngineConfig fromMap(Map<Object?, Object?> map) {
    bool? boolField(String key) {
      final v = map[key];
      if (v is bool) return v;
      if (v is num) return v != 0;
      if (v is String) {
        switch (v) {
          case 'true':
          case '1':
            return true;
          case 'false':
          case '0':
            return false;
        }
      }
      return null;
    }

    int? intField(String key) {
      final v = map[key];
      if (v is int) return v;
      if (v is num) return v.toInt();
      if (v is String) return int.tryParse(v);
      return null;
    }

    double? doubleField(String key) {
      final v = map[key];
      if (v is double) return v;
      if (v is num) return v.toDouble();
      if (v is String) return double.tryParse(v);
      return null;
    }

    return AdaptiveEngineConfig(
      adaptiveEngine: boolField('adaptiveEngine') ?? true,
      proximityRadiusM: intField('proximityRadiusM'),
      hysteresis: (doubleField('hysteresis') ?? 0.15).clamp(0.0, 0.45),
      accuracyGate: boolField('accuracyGate') ?? true,
      maxFixAccuracyM: intField('maxFixAccuracyM'),
      confirmationFixes: intField('confirmationFixes')?.clamp(1, 5),
      loiteringDelayMs: intField('loiteringDelayMs') ?? 0,
      stopTimeoutSeconds: intField('stopTimeoutSeconds') ?? 180,
      heartbeatIntervalSeconds: intField('heartbeatIntervalSeconds') ?? 300,
      initialTriggerEnter: boolField('initialTriggerEnter') ?? true,
      initialTriggerExit: boolField('initialTriggerExit') ?? true,
      emitHeartbeatEvents: boolField('emitHeartbeatEvents') ?? false,
    );
  }
}

/// Provenance of a geofence event.
enum GeofenceEventSource {
  /// Committed by the engine's own fix-stream evaluation.
  fix('fix'),

  /// Committed by the OS geofence tripwire (region monitoring).
  osRegion('os-region'),

  /// Synthesized by the periodic heartbeat (liveness, not a transition).
  heartbeat('heartbeat'),

  /// Synthesized by start/relaunch reconciliation (missed transitions).
  reconcile('reconcile'),

  /// Synthesized by the boot receiver after a device reboot.
  boot('boot');

  /// Const constructor — carries the [wireName].
  const GeofenceEventSource(this.wireName);

  /// The stable cross-platform wire string for this source.
  final String wireName;

  /// Tolerant parser — an unknown or missing wire resolves to
  /// [GeofenceEventSource.fix].
  static GeofenceEventSource fromWire(String? wire) =>
      GeofenceEventSource.values.firstWhere(
        (s) => s.wireName == wire,
        orElse: () => GeofenceEventSource.fix,
      );
}

/// Enriched geofence transition event with full provenance.
///
/// This is the event contract of the motion-aware adaptive engine. A
/// minimal five-field shape is also available as
/// `package:geofence_kit/legacy/geofence_event.dart`
/// ([LegacyGeofenceEvent]). Consumers can keep reading `transition` /
/// `fenceId` / `timestamp` unchanged across both shapes.
class GeofenceEvent {
  /// Stable event id — the dedup + acknowledgement key (empty for
  /// legacy rows, which are delivered as-is).
  final String id;

  /// Id of the fence that fired.
  final String fenceId;

  /// "ENTER", "EXIT" or "DWELL".
  final String transition;

  /// Wall-clock ms since the Unix epoch.
  final int timestampMs;

  /// Event location latitude in degrees (-1 when the OS supplied none).
  final double latitude;

  /// Event location longitude in degrees (-1 when the OS supplied none).
  final double longitude;

  /// Fix accuracy in meters (-1 when unavailable).
  final double accuracy;

  /// Event location speed in meters per second (-1 when unavailable).
  final double speed;

  /// Event location bearing in degrees, 0 = due north (-1 when
  /// unavailable).
  final double bearing;

  /// Provenance of the commit.
  final GeofenceEventSource source;

  /// Distance from the event location to the fence center, meters.
  final double distanceToCenterMeters;

  /// Proximity tier at commit time ("far" | "near" | "edge").
  final String tier;

  /// Motion classification at commit time ("still" | "foot" | "vehicle" | "unknown").
  final String motion;

  /// Heuristic confidence in [0, 1].
  final double confidence;

  /// Fence registration generation at commit time. Identifies the
  /// OS registration round the commit belongs to; consumers can discard
  /// evidence armed under a superseded registration. `0` for legacy events.
  final int registrationGeneration;

  /// `true` ONLY for outbox-replay deliveries — live dispatch is
  /// always `false`. Delivery is at-least-once with stable [id]s: an
  /// unacknowledged event replays (flagged) until acknowledged; the facade
  /// suppresses duplicates by [id], so application callbacks see an event
  /// at most once per process.
  final bool replayed;

  /// `true` when the payload location is DEGRADED — no fresh fix
  /// existed at commit, so [latitude]/[longitude] carry the fence center
  /// and [accuracy] the bounding radius. Degraded events carry LOW
  /// confidence; the asynchronous payload request that follows never
  /// amends them.
  final bool payloadDegraded;

  /// Caller fence metadata passthrough (`null` for fences defined
  /// without `Geofence.extras`).
  final Map<String, Object?>? extras;

  /// Creates an enriched event — normally parsed via [fromMap] off the
  /// event channel rather than constructed by hand.
  const GeofenceEvent({
    required this.id,
    required this.fenceId,
    required this.transition,
    required this.timestampMs,
    required this.latitude,
    required this.longitude,
    required this.accuracy,
    required this.speed,
    required this.bearing,
    required this.source,
    required this.distanceToCenterMeters,
    required this.tier,
    required this.motion,
    required this.confidence,
    this.registrationGeneration = 0,
    this.replayed = false,
    this.payloadDegraded = false,
    this.extras,
  });

  /// `true` when [transition] is `"ENTER"`.
  bool get isEnter => transition == 'ENTER';

  /// `true` when [transition] is `"EXIT"`.
  bool get isExit => transition == 'EXIT';

  /// `true` when [transition] is `"DWELL"`.
  bool get isDwell => transition == 'DWELL';

  /// Tolerant parser for the event-channel payload — missing keys fall
  /// back to inert defaults, and enrichment keys are additive.
  static GeofenceEvent fromMap(Map<Object?, Object?> map) {
    double d(String key, [double fallback = -1]) =>
        (map[key] as num?)?.toDouble() ?? fallback;
    return GeofenceEvent(
      id: map['id'] as String? ?? '',
      fenceId: map['fenceId'] as String? ?? '',
      transition: map['transition'] as String? ?? '',
      timestampMs: (map['timestampMs'] as num?)?.toInt() ?? 0,
      latitude: d('latitude'),
      longitude: d('longitude'),
      accuracy: d('accuracy'),
      speed: d('speed'),
      bearing: d('bearing'),
      source: GeofenceEventSource.fromWire(map['source'] as String?),
      distanceToCenterMeters: d('distanceToCenterMeters'),
      tier: map['tier'] as String? ?? 'far',
      motion: map['motion'] as String? ?? 'unknown',
      confidence: d('confidence', 0),
      registrationGeneration: (map['gen'] as num?)?.toInt() ?? 0,
      replayed: map['replayed'] as bool? ?? false,
      payloadDegraded: map['payloadDegraded'] as bool? ?? false,
      extras: map['extras'] as Map<String, Object?>?,
    );
  }

  /// Wire map (round-trips [fromMap]; `gen` carries
  /// [registrationGeneration]).
  Map<String, Object?> toMap() => <String, Object?>{
        'id': id,
        'fenceId': fenceId,
        'transition': transition,
        'timestampMs': timestampMs,
        'latitude': latitude,
        'longitude': longitude,
        'accuracy': accuracy,
        'speed': speed,
        'bearing': bearing,
        'source': source.wireName,
        'distanceToCenterMeters': distanceToCenterMeters,
        'tier': tier,
        'motion': motion,
        'confidence': confidence,
        'gen': registrationGeneration,
        'replayed': replayed,
        'payloadDegraded': payloadDegraded,
        if (extras != null) 'extras': extras,
      };
}
