// geofence_kit — minimal event shape.
//
// [LegacyGeofenceEvent] is the five-field core of the event wire format
// (fenceId / transition / timestampMs / latitude / longitude) — the shape
// to type against when a consumer does not need the engine's enrichment
// (source/tier/motion/confidence/…). It is deliberately tolerant:
//  - payloads from the full [GeofenceEvent] wire format parse cleanly
//    (the enrichment keys are simply ignored), and
//  - the internal config switch `AdaptiveEngineConfig(adaptiveEngine:
//    false)` runs the engine in plain OS-tripwire mode, which emits
//    exactly this shape.
//
// The enriched contract ([GeofenceEvent], with full provenance) is
// re-exported from package:geofence_kit/geofence_kit.dart — new code
// should consume that.

/// A geofence transition event in the minimal five-field shape.
///
/// Consumers that want the full provenance should use [GeofenceEvent] from
/// `package:geofence_kit/geofence_kit.dart` instead.
class LegacyGeofenceEvent {
  /// Id of the fence that fired.
  final String fenceId;

  /// "ENTER", "EXIT" or "DWELL" ([isEnter]/[isExit] cover the first
  /// two; the string is carried through unmodified).
  final String transition;

  /// Wall-clock ms since the Unix epoch.
  final int timestampMs;

  /// Event location latitude in degrees (-1 when the OS supplied none).
  final double latitude;

  /// Event location longitude in degrees (-1 when the OS supplied none).
  final double longitude;

  /// Creates a minimal event — normally parsed via [fromWire] off the
  /// platform wire map rather than constructed by hand.
  const LegacyGeofenceEvent({
    required this.fenceId,
    required this.transition,
    required this.timestampMs,
    required this.latitude,
    required this.longitude,
  });

  /// `true` when [transition] is `"ENTER"`.
  bool get isEnter => transition == 'ENTER';

  /// `true` when [transition] is `"EXIT"`.
  bool get isExit => transition == 'EXIT';

  /// Tolerant parser for the platform wire map — reads ONLY the five
  /// core fields and ignores the enrichment keys (source/tier/motion/
  /// confidence/…) carried by the full [GeofenceEvent] payload.
  static LegacyGeofenceEvent fromWire(Map<Object?, Object?> map) {
    return LegacyGeofenceEvent(
      fenceId: map['fenceId'] as String? ?? '',
      transition: map['transition'] as String? ?? '',
      timestampMs: (map['timestampMs'] as num?)?.toInt() ?? 0,
      latitude: (map['latitude'] as num?)?.toDouble() ?? -1,
      longitude: (map['longitude'] as num?)?.toDouble() ?? -1,
    );
  }

  /// The five core fields as a plain map (round-trips [fromWire]).
  Map<String, Object?> toMap() => <String, Object?>{
        'fenceId': fenceId,
        'transition': transition,
        'timestampMs': timestampMs,
        'latitude': latitude,
        'longitude': longitude,
      };
}
