// geofence_kit example — main entry.
//
// Registers the reference geofence ON APP BOOT (no button, no user action)
// and observes geofence events in every app state:
//
//   foreground  → live event log below + (optionally) in-app notifications
//   background  → local notifications (plugin-native) + this log on return
//   terminated  → local notifications (plugin-native) + outbox replay on
//                 next launch (`flushOutbox`)
//
// The fence: lat 40.782849, lng -73.965572, radius 250 m, dwell 30 s.

import 'dart:async';

import 'package:flutter/material.dart';

import 'package:geofence_kit/geofence_kit.dart';

import 'event_log.dart';
import 'snapshot_panel.dart';

/// The reference fence used by every geofence_kit verification run.
const Geofence kReferenceFence = Geofence(
  id: 'reference-fence',
  latitude: 40.782849,
  longitude: -73.965572,
  radiusMeters: 250,
);

/// DWELL fires 30 s after ENTER commits — and survives process death.
const Duration kDwell = Duration(seconds: 30);

void main() {
  runApp(const GfkExampleApp());
}

class GfkExampleApp extends StatelessWidget {
  const GfkExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'geofence_kit example',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF0F766E)),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF0F766E),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const ExampleHomePage(),
    );
  }
}

class ExampleHomePage extends StatefulWidget {
  const ExampleHomePage({super.key});

  @override
  State<ExampleHomePage> createState() => _ExampleHomePageState();
}

class _ExampleHomePageState extends State<ExampleHomePage>
    with WidgetsBindingObserver {
  AppLifecycleState _lifecycle = AppLifecycleState.detached;

  /// Newest first.
  final List<LoggedEvent> _events = <LoggedEvent>[];

  Map<String, Object?> _snapshot = const {};
  StreamSubscription<GeofenceEvent>? _subscription;
  Timer? _snapshotTimer;
  String _status = 'booting…';
  bool _started = false;

  /// False when the engine started WITHOUT the background-location
  /// grant — the engine is then foreground-only (no events while
  /// backgrounded/terminated), which the banner below must make obvious.
  bool _bgLocationGranted = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _lifecycle = WidgetsBinding.instance.lifecycleState ?? _lifecycle;
    // Register on boot: the first frame guarantees the engine can surface
    // permissions UI if it needs to.
    WidgetsBinding.instance.addPostFrameCallback((_) => _bootstrap());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _subscription?.cancel();
    _snapshotTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    setState(() => _lifecycle = state);
    if (state == AppLifecycleState.resumed) {
      // Pull events that fired while we were backgrounded/killed, then
      // refresh the engine panel + the background-grant banner (the user
      // may have just granted "Allow all the time" in Settings).
      GeofenceKit.instance.flushOutbox();
      _refreshSnapshot();
      _refreshPermissionState();
    }
  }

  /// Re-reads the runtime permission state — the settings grant
  /// can change any time the user visits the app's system settings page.
  Future<void> _refreshPermissionState() async {
    try {
      final status = await GeofenceKit.instance.permissionStatus();
      if (mounted) {
        setState(
            () => _bgLocationGranted = status['locationBackground'] == true);
      }
    } catch (_) {
      // Platform view gone — the banner simply keeps its last state.
    }
  }

  // MARK: Boot registration

  Future<void> _bootstrap() async {
    setState(() => _status = 'registering fence…');
    try {
      final result = await GeofenceKit.instance.start(
        fences: const [kReferenceFence],
        dwell: kDwell,
        // The plugin's single notification knob — its native
        // "geofence_kit · <EVENT> · <fenceId>" / "captured NATIVELY (…)"
        // debug note (every app state). The app's own event surfacing is
        // the onEvent stream below.
        showDebugNotification: true,
      );
      _subscription?.cancel();
      _subscription = GeofenceKit.instance.onEvent.listen(
        (event) => _onEvent(event, appState: _lifecycle),
        onError: (Object error) {
          setState(() => _status = 'stream error: $error');
        },
      );
      setState(() {
        _started = result.started;
        _bgLocationGranted = result.backgroundLocationGranted;
        _status = result.started
            ? 'tracking ${result.fencesRegistered} fence(s)'
            : 'engine refused (see logs)';
      });
      await _refreshSnapshot();
    } catch (error) {
      setState(() => _status = 'start failed: $error');
    }
    _snapshotTimer?.cancel();
    _snapshotTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (_lifecycle == AppLifecycleState.resumed) _refreshSnapshot();
    });
  }

  void _onEvent(GeofenceEvent event, {required AppLifecycleState appState}) {
    setState(() {
      _events.insert(
        0,
        LoggedEvent(event: event, appStateAtReceive: appState),
      );
      if (_events.length > 500) _events.removeLast();
    });
  }

  Future<void> _refreshSnapshot() async {
    try {
      final snap = await GeofenceKit.instance.engineStateSnapshot();
      if (mounted) setState(() => _snapshot = snap);
    } catch (_) {
      // Engine not attached yet — the panel shows placeholders.
    }
  }

  // MARK: UI

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('geofence_kit · example'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Center(child: _LifecycleChip(state: _lifecycle)),
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(40),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                _status,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_started && !_bgLocationGranted) ...[
            _BackgroundLocationWarning(
              onFix: () => GeofenceKit.instance.openAppSettings(),
            ),
            const SizedBox(height: 16),
          ],
          _FenceCard(started: _started),
          const SizedBox(height: 16),
          SnapshotPanel(snapshot: _snapshot),
          const SizedBox(height: 16),
          Text(
            'Event log (newest first)',
            style: theme.textTheme.titleMedium,
          ),
          const SizedBox(height: 4),
          Text(
            'Received here: ${_events.length} · '
            'background/terminated events also arrive as local notifications '
            'and replay from the outbox on relaunch.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          if (_events.isEmpty)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  'No events yet — cross the fence boundary '
                  '(lat 40.782849, lng -73.965572, r 250 m) on foot or by car.\n'
                  'Then background the app, or terminate it, and cross again: '
                  'notifications prove delivery in every state.',
                  style: theme.textTheme.bodyMedium,
                ),
              ),
            )
          else
            ..._events.map(
              (logged) => EventLogTile(logged: logged),
            ),
          const SizedBox(height: 24),
          FilledButton.tonalIcon(
            onPressed: () => setState(_events.clear),
            icon: const Icon(Icons.clear_all),
            label: const Text('Clear log'),
          ),
        ],
      ),
    );
  }
}

/// Amber warning banner shown while the engine runs WITHOUT the
/// background-location grant — the state that masquerades as a
/// healthy engine while no event can ever fire in background/terminated.
class _BackgroundLocationWarning extends StatelessWidget {
  const _BackgroundLocationWarning({required this.onFix});

  final VoidCallback onFix;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      color: Colors.amber.withValues(alpha: 0.15),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.warning_amber_rounded, color: Colors.amber),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Background location is OFF',
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'The engine tracks only while this app is on screen. NO '
              'ENTER/DWELL/EXIT events fire while it is backgrounded or '
              'killed — grant location "Allow all the time" and the fence '
              'tripwires work in every app state.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: onFix,
              icon: const Icon(Icons.settings),
              label: const Text('Fix in Settings'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Chip showing the current Flutter lifecycle state — the same annotation
/// attached to every received event.
class _LifecycleChip extends StatelessWidget {
  const _LifecycleChip({required this.state});

  final AppLifecycleState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (label, color) = switch (state) {
      AppLifecycleState.resumed => ('FOREGROUND', Colors.teal),
      AppLifecycleState.inactive => ('INACTIVE', Colors.amber),
      AppLifecycleState.paused => ('BACKGROUND', Colors.orange),
      AppLifecycleState.hidden => ('HIDDEN', Colors.deepOrange),
      AppLifecycleState.detached => ('TERMINATED', Colors.redAccent),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(
          color: color,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

/// Reference fence summary card.
class _FenceCard extends StatelessWidget {
  const _FenceCard({required this.started});

  final bool started;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  started ? Icons.my_location : Icons.my_location_outlined,
                  color: started ? Colors.teal : theme.disabledColor,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'reference-fence · 250 m',
                    style: theme.textTheme.titleMedium,
                  ),
                ),
                _Dot(active: started),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'center 40.782849, -73.965572\n'
              'registered on app boot · dwell 30 s · re-registers after device '
              'reboot',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Dot extends StatelessWidget {
  const _Dot({required this.active});

  final bool active;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 12,
      height: 12,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: active ? Colors.teal : Colors.grey,
      ),
    );
  }
}
