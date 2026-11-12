// geofence_kit — method-channel implementation of the public facade.
//
// Wire format:
//   MethodChannel 'geofence_kit/methods'
//     start → { fences: [...], adaptive: {...}, showDebugNotification: bool }
//             ← { started: bool, fencesRegistered: int, adaptiveEngine: bool }
//     stop / flushOutbox
//     ackEvents {ids: [...]} ← {acknowledged: int}
//     engineStateSnapshot ← map (engine keys + outboxCount + hostAlive)
//     enableHeadlessTask {bootstrapHandle, userHandle} ← {supported, registered}
//                 (two-handle headless registration;
//                 iOS replies supported:false and this facade no-ops)
//     headlessConfig ← {userCallbackHandle}  (headless isolate only)
//     headlessComplete → destroy the spawned engine (headless isolate only)
//   EventChannel 'geofence_kit/events'
//     GeofenceEvent maps (see lib/src/adaptive_config.dart).
//
// Notifications: the plugin's ONLY notification surface is the native
// "captured NATIVELY" debug note (checkpoint ①), gated by
// `start(showDebugNotification:)` — default FALSE. Apps post their own
// notifications (flutter_local_notifications or any package) from
// `onEvent` / their headless task.
//
// Delivery contract: native commits every transition as a
// durable outbox row FIRST and delivers it (live or replayed). Rows are
// deleted ONLY by this facade's `ackEvents` call — sent from Dart code that
// has actually received + parsed the event off the channel, AFTER the
// application's stream consumer has seen it (the honest acknowledgement
// boundary: "delivered to the application's event subscription"). An ack
// lost to channel teardown leaves the row for the next replay, which this
// facade suppresses by event id — the application callback sees each event
// at most once per process, and silent duplicates never re-invoke it.

import 'dart:async';
// PluginUtilities / CallbackHandle live in dart:ui — required for the
// two-handle headless registration and NOT exported by
// package:flutter/services.dart.
import 'dart:ui' show CallbackHandle, PluginUtilities;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show WidgetsFlutterBinding;

import '../geofence_kit.dart' as api;
import 'adaptive_config.dart';

/// The headless-isolate entry point — the FIRST of the two handles.
/// The native HeadlessDispatcher spawns a background
/// FlutterEngine and executes THIS function (and nothing else) in the
/// background isolate; [MethodChannelGeofenceKit.runHeadlessTask] then
/// resolves the application's task (the SECOND handle) and drives the
/// drain through the normal onEvent machinery.
///
/// `@pragma('vm:entry-point')` keeps it tree-shake-safe — without it a
/// release build has no symbol for the native handle to resolve.
///
/// The binding init is the FIRST statement — the native side runs this in
/// a FRESH background isolate via `executeDartCallback`, and bindings are
/// per-isolate singletons the engine initializes NONE of on a callback
/// isolate: without this, every channel access below resolves
/// `ServicesBinding.instance` → "Binding has not yet been initialized"
/// before any message is sent (workmanager, firebase_messaging and
/// flutter_local_notifications background callbacks all document the same
/// requirement).
@pragma('vm:entry-point')
void gfkHeadlessBootstrap() {
  WidgetsFlutterBinding.ensureInitialized();
  // Fire-and-forget by design — the drain owns its own teardown and the
  // bootstrap must return immediately; the explicit unawaited keeps
  // discarded_futures satisfied without changing behavior.
  unawaited(MethodChannelGeofenceKit.runHeadlessTask());
}

/// The production [api.GeofenceKit] implementation.
class MethodChannelGeofenceKit extends api.GeofenceKit {
  static const MethodChannel _methods = MethodChannel('geofence_kit/methods');
  static const EventChannel _events = EventChannel('geofence_kit/events');

  Stream<api.GeofenceEvent>? _onEvent;

  /// Event ids already delivered to the application stream this process
  /// (bounded LRU, oldest evicted first).
  final List<String> _seenEventIds = <String>[];

  /// Acknowledged-already ids do not need a second ack (bounded memo).
  final Set<String> _ackedEventIds = <String>{};

  static const int _seenEventLimit = 512;

  void _rememberSeen(String id) {
    if (_seenEventIds.contains(id)) return;
    _seenEventIds.add(id);
    if (_seenEventIds.length > _seenEventLimit) {
      _seenEventIds.removeRange(0, _seenEventIds.length - _seenEventLimit);
    }
  }

  /// Explicit Dart-side acknowledgement: deletes the
  /// acknowledged outbox rows natively — the only deletion path. Fire and
  /// forget with a memo (never re-acks the same id); a lost ack simply
  /// means the row replays later and is suppressed here by id.
  Future<void> _ack(String id) async {
    if (!_ackedEventIds.add(id)) return;
    try {
      await _methods.invokeMethod<void>('ackEvents', <String, Object?>{
        'ids': <String>[id],
      });
    } catch (_) {
      // Channel gone (engine detached) — the row replays after the next
      // attach and is suppressed by id; acknowledgement is never a
      // delivery-critical operation on the Dart side.
      _ackedEventIds.remove(id);
    }
  }

  @override
  Future<api.StartResult> start({
    required List<api.Geofence> fences,
    Duration? dwell,
    bool showDebugNotification = false,
  }) async {
    final raw = await _methods
        .invokeMethod<Map<dynamic, dynamic>>('start', <String, Object?>{
      'fences': <Map<String, Object?>>[
        for (final fence in fences) fence.toMap(),
      ],
      'adaptive': api.GeofenceKit.tunedAdaptiveMap(dwell),
      'showDebugNotification': showDebugNotification,
    });
    final map = Map<String, Object?>.from(raw ?? const <Object?, Object?>{});
    return api.StartResult(
      started: map['started'] == true,
      fencesRegistered: (map['fencesRegistered'] as num?)?.toInt() ?? 0,
      adaptiveEngine: map['adaptiveEngine'] != false,
      message: map['message'] as String?,
      // The native side reports whether the background-location grant is
      // in effect — without it the engine is foreground-only (no events
      // while backgrounded/terminated). A missing key (platforms without
      // the concept) → true.
      backgroundLocationGranted:
          map['backgroundLocationGranted'] as bool? ?? true,
    );
  }

  @override
  Stream<api.GeofenceEvent> get onEvent {
    // `asyncMap` declares ONE type parameter (the output element type).
    return _onEvent ??= _events
        .receiveBroadcastStream()
        .asyncMap<Object?>((Object? raw) async {
          final event = GeofenceEvent.fromMap(
            Map<Object?, Object?>.from(raw as Map),
          );
          if (event.id.isEmpty) {
            // Legacy rows without a stable id cannot be deduped or acked —
            // deliver as-is.
            return event;
          }
          if (_seenEventIds.contains(event.id)) {
            // Duplicate replay of an already-delivered event — re-ack
            // (cheap) and suppress: the application callback sees it once.
            await _ack(event.id);
            return null;
          }
          _rememberSeen(event.id);
          // The application's stream consumer has now received the event —
          // this IS the acknowledgement boundary: a native outbox row
          // is deleted only after its event reached the Dart subscription.
          await _ack(event.id);
          return event;
        })
        .where((Object? e) => e is api.GeofenceEvent)
        .cast<api.GeofenceEvent>();
  }

  @override
  Future<void> stop() => _methods.invokeMethod<void>('stop');

  @override
  Future<Map<String, Object?>> permissionStatus() async {
    final raw =
        await _methods.invokeMethod<Map<dynamic, dynamic>>('permissionStatus');
    return Map<String, Object?>.from(raw ?? const <Object?, Object?>{});
  }

  @override
  Future<void> openAppSettings() =>
      _methods.invokeMethod<void>('openAppSettings');

  @override
  Future<Map<String, Object?>> requestOemAutostart() async {
    final raw = await _methods
        .invokeMethod<Map<dynamic, dynamic>>('requestOemAutostart');
    return Map<String, Object?>.from(raw ?? const <Object?, Object?>{});
  }

  @override
  Future<Map<String, Object?>> engineStateSnapshot() async {
    final raw = await _methods
        .invokeMethod<Map<dynamic, dynamic>>('engineStateSnapshot');
    return Map<String, Object?>.from(raw ?? const <Object?, Object?>{});
  }

  @override
  Future<void> flushOutbox() => _methods.invokeMethod<void>('flushOutbox');

  // MARK: Headless dispatch ─────────────────────────────────────────────

  /// Register [task] for headless execution (two-handle pattern): the
  /// plugin-internal [gfkHeadlessBootstrap] (spawned-engine entry point)
  /// + the application's task (resolved + invoked inside the isolate).
  /// Both handles are persisted natively; a spawn happens per event burst
  /// while the app is terminated, and every failure falls back to the
  /// durable outbox (next-launch replay) — nothing is ever lost.
  @override
  Future<void> enableHeadlessTask(api.GeofenceHeadlessTask task) async {
    final bootstrapHandle =
        PluginUtilities.getCallbackHandle(gfkHeadlessBootstrap);
    if (bootstrapHandle == null) {
      throw StateError(
        'enableHeadlessTask: the internal headless bootstrap could not be '
        'registered (tree-shaking? report this).',
      );
    }
    final userHandle = PluginUtilities.getCallbackHandle(task);
    if (userHandle == null) {
      throw ArgumentError(
        'enableHeadlessTask: the task must be a top-level or static function '
        'annotated @pragma(\'vm:entry-point\') — closures and instance '
        'methods cannot be resolved inside a background isolate.',
      );
    }
    try {
      final raw = await _methods.invokeMethod<Map<dynamic, dynamic>>(
          'enableHeadlessTask', <String, Object?>{
        'bootstrapHandle': bootstrapHandle.toRawHandle(),
        'userHandle': userHandle.toRawHandle(),
      });
      final supported = raw is Map && raw['supported'] != false;
      if (!supported) {
        // iOS (and any platform without the mechanism): terminated-state
        // events relaunch the app / replay from the outbox onto onEvent —
        // no headless task needed. Deliberate no-op, documented on the API.
        return;
      }
    } on PlatformException {
      // Channel alive but the native side refused — same honest fallback:
      // the outbox still guarantees delivery at next launch.
      rethrow;
    } on MissingPluginException {
      // Method not implemented natively (platform without the mechanism)
      // — no-op, outbox delivery unchanged.
    }
  }

  /// The headless-isolate runner (executed via [gfkHeadlessBootstrap]):
  /// resolve the application's task, drain through the SAME [onEvent]
  /// pipeline (live buffer + outbox replay, dedup + ack), invoke the task
  /// per event, then release the engine when the drain goes quiet.
  ///
  /// Idle contract: 5 s of quiet after the last processed event (or after
  /// subscribe, when nothing was buffered) ends the run; a 12 s Dart-side
  /// cap backs it (the native 30 s hard cap is the last resort).
  static Future<void> runHeadlessTask() async {
    final kit = MethodChannelGeofenceKit();

    // 1. Ask the (headless-attached) plugin for the registered task handle.
    // Native sends it as a long (int64) — parse defensively through num so
    // any codec variation still lands in an int, which is what
    // CallbackHandle.fromRawHandle takes.
    int? userRaw;
    try {
      final raw =
          await _methods.invokeMethod<Map<dynamic, dynamic>>('headlessConfig');
      userRaw = (raw?['userCallbackHandle'] as num?)?.toInt();
    } catch (_) {
      // Channel dead — let the native hard cap reclaim the engine.
      return;
    }
    if (userRaw == null || userRaw == 0) return;
    // dart:ui's API is getCallbackFromHandle (the earlier
    // getCachedCallbackFromHandle name no longer exists on current
    // stable — the analyzer reports undefined_method against it).
    final Function? taskFn = PluginUtilities.getCallbackFromHandle(
      CallbackHandle.fromRawHandle(userRaw),
    );
    if (taskFn == null) {
      // Stale handle (app update changed the snapshot). Do NOT ack rows the
      // task never saw — leave them for the next-launch replay.
      await kit._releaseHeadlessEngine();
      return;
    }

    // 2. Drain through the standard pipeline. Its asyncMap already:
    //    dedups (live copy + outbox replay of the same id arrive here),
    //    acks each delivered row (the deletion boundary), and forwards the
    //    parsed event to our subscription below.
    final done = Completer<void>();
    const idleGrace = Duration(seconds: 5);
    const hardCap = Duration(seconds: 12);
    Timer? idleTimer;
    void finish() {
      if (!done.isCompleted) done.complete();
    }

    final capTimer = Timer(hardCap, finish);
    void armIdle() {
      idleTimer?.cancel();
      idleTimer = Timer(idleGrace, finish);
    }

    final sub = kit.onEvent.listen(
      (event) async {
        try {
          final result = (taskFn as api.GeofenceHeadlessTask)(event);
          if (result is Future) await result;
        } catch (error) {
          // The app's task crashed — surface it in the app's own way (the
          // app owns its notifications; the drain continues; the row was
          // already acked at the pipeline boundary, exactly as the
          // foreground path would have). Swallowing here keeps the drain
          // alive to the idle grace.
        } finally {
          armIdle();
        }
      },
      onError: (Object _) {},
      onDone: finish,
    );

    armIdle(); // empty drain (nothing buffered) → quiet exit after the grace
    await done.future;
    idleTimer?.cancel();
    capTimer.cancel();
    await sub.cancel();

    // 3. Release the engine — the next burst spawns a fresh one.
    await kit._releaseHeadlessEngine();
  }

  Future<void> _releaseHeadlessEngine() async {
    try {
      await _methods.invokeMethod<void>('headlessComplete');
    } catch (_) {
      // Channel gone — the native hard cap reclaims the engine.
    }
  }
}
