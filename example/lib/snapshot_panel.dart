// geofence_kit example — engine observability panel.
//
// Live view of `GeofenceKit.instance.engineStateSnapshot()`: which preset
// the motion-aware engine is running, the proximity tier, the motion
// classifier actually in use (activity recognition / sensor fusion / speed
// heuristic), the location provider (gms-fused / hms-fused / platform),
// heartbeat beats and the pending outbox count.

import 'package:flutter/material.dart';

class SnapshotPanel extends StatelessWidget {
  const SnapshotPanel({super.key, required this.snapshot});

  final Map<String, Object?> snapshot;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final running = snapshot['running'] == true;
    final rows = <(String, String)>[
      ('running', running ? 'yes' : 'no'),
      ('preset', '${snapshot['preset'] ?? '–'}'),
      ('tier', '${snapshot['tier'] ?? '–'}'),
      ('motion', '${snapshot['motion'] ?? '–'}'),
      ('motion source', '${snapshot['motionSource'] ?? '–'}'),
      ('location provider', '${snapshot['locationProvider'] ?? '–'}'),
      ('background location', snapshot.containsKey('locationBackground')
          ? (snapshot['locationBackground'] == true ? 'granted' : 'OFF (foreground-only)')
          : '–'),
      ('heartbeats', '${snapshot['beats'] ?? '–'}'),
      ('outbox (buffered)', '${snapshot['outboxCount'] ?? '–'}'),
      ('outbox mode', '${snapshot['outboxMode'] ?? '–'}'),
    ];
    final lastFix = snapshot['lastFix'];
    if (lastFix is Map) {
      rows.add((
        'last fix',
        '${_fmt(lastFix['lat'])}, ${_fmt(lastFix['lng'])} ±'
            '${_fmt(lastFix['accuracy'])} m',
      ));
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.monitor_heart,
                  size: 18,
                  color: running ? Colors.teal : theme.disabledColor,
                ),
                const SizedBox(width: 8),
                Text('Engine (live)', style: theme.textTheme.titleMedium),
              ],
            ),
            const SizedBox(height: 8),
            Table(
              columnWidths: const {
                0: IntrinsicColumnWidth(),
                1: FlexColumnWidth(),
              },
              defaultVerticalAlignment: TableCellVerticalAlignment.middle,
              children: [
                for (final (label, value) in rows)
                  TableRow(children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 4, right: 12),
                      child: Text(
                        label,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        value,
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ]),
              ],
            ),
          ],
        ),
      ),
    );
  }

  static String _fmt(Object? v) {
    final d = v is num ? v.toDouble() : double.tryParse('$v');
    if (d == null) return '$v';
    return d.toStringAsFixed(d.abs() < 100 ? 4 : 0);
  }
}
