// geofence_kit example — event log widgets.

import 'package:flutter/material.dart';

import 'package:geofence_kit/geofence_kit.dart';

/// One received event plus the Dart-side app lifecycle state at the moment
/// of receipt — the annotation that makes state-coverage visible in the log.
class LoggedEvent {
  const LoggedEvent({required this.event, required this.appStateAtReceive});

  final GeofenceEvent event;
  final AppLifecycleState appStateAtReceive;
}

class EventLogTile extends StatelessWidget {
  const EventLogTile({super.key, required this.logged});

  final LoggedEvent logged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final event = logged.event;

    final (icon, color, label) = switch (event.transition) {
      'ENTER' => (Icons.login, Colors.teal, 'ENTER'),
      'EXIT' => (Icons.logout, Colors.redAccent, 'EXIT'),
      'DWELL' => (Icons.timelapse, Colors.amber, 'DWELL'),
      _ => (Icons.help_outline, Colors.grey, event.transition),
    };

    final time = DateTime.fromMillisecondsSinceEpoch(event.timestampMs);
    final clock =
        '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}:'
        '${time.second.toString().padLeft(2, '0')}';

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, color: color, size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '$label · ${event.fenceId}',
                    style: theme.textTheme.titleSmall
                        ?.copyWith(color: color, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'src ${event.source.wireName} · tier ${event.tier} · '
                    'motion ${event.motion}\n'
                    'dist ${_fmt(event.distanceToCenterMeters)} m · '
                    'acc ${_fmt(event.accuracy)} m · '
                    'conf ${(event.confidence * 100).toStringAsFixed(0)}%',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  clock,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                const SizedBox(height: 4),
                _AppStateBadge(state: logged.appStateAtReceive),
              ],
            ),
          ],
        ),
      ),
    );
  }

  static String _fmt(double v) =>
      v < 0 ? '–' : v.toStringAsFixed(v < 100 ? 1 : 0);
}

class _AppStateBadge extends StatelessWidget {
  const _AppStateBadge({required this.state});

  final AppLifecycleState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final label = switch (state) {
      AppLifecycleState.resumed => 'fg',
      AppLifecycleState.inactive => 'inact',
      AppLifecycleState.paused => 'bg',
      AppLifecycleState.hidden => 'hidden',
      AppLifecycleState.detached => 'killed',
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
