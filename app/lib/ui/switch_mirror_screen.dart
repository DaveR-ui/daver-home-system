import 'package:flutter/material.dart';

import '../hub/hub_client.dart';
import '../hub/hub_status_controller.dart';
import '../surfaces/light_entity.dart';

/// The switch-mirror screen: the switch's state plus the bulbs its Home
/// Assistant automation drives.
///
/// STATUS ONLY. It exposes no write path — no toggle on the switch and no
/// buttons on the bulbs: the switch's automation is the only writer, and each
/// bulb is controlled from its own screen (ADR-0005). This is what proves there
/// is no second write path to the bulbs.
class SwitchMirrorScreen extends StatelessWidget {
  const SwitchMirrorScreen({
    super.key,
    required this.controller,
    required this.entityId,
  });

  /// The app's render cache and reachability model.
  final HubStatusController controller;

  /// The `switch.*` entity this screen mirrors.
  final String entityId;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Switch mirror')),
      body: AnimatedBuilder(
        animation: controller,
        builder: (BuildContext context, Widget? child) {
          final LightEntity? sw = _findSwitch();
          if (sw == null) {
            return const Center(child: Text('Entity not found.'));
          }
          return _buildBody(context, sw);
        },
      ),
    );
  }

  LightEntity? _findSwitch() {
    for (final EntitySnapshot snapshot in controller.entities) {
      if (snapshot.entityId == entityId) {
        return LightEntity.from(snapshot);
      }
    }
    return null;
  }

  Widget _buildBody(BuildContext context, LightEntity sw) {
    final List<LightEntity> bulbs = linkedBulbsFor(sw, controller.entities);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: <Widget>[
        Row(
          children: <Widget>[
            Icon(sw.isOn ? Icons.toggle_on : Icons.toggle_off),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    sw.device,
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  Text('State: ${sw.isOn ? 'on' : 'off'} (read-only)'),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        const Card(
          child: Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              "This switch's Home Assistant automation drives these bulbs. "
              'Status only — control each bulb from its own screen.',
            ),
          ),
        ),
        const SizedBox(height: 16),
        Text(
          'Bulbs this automation drives',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        if (bulbs.isEmpty)
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text('No linked bulbs found.'),
          )
        else
          for (final LightEntity bulb in bulbs)
            ListTile(
              title: Text(bulb.device),
              subtitle: Text(_bulbState(bulb)),
              // Read-only: no onTap, no toggle.
            ),
      ],
    );
  }

  static String _bulbState(LightEntity bulb) {
    final String state = bulb.isOn ? 'on' : 'off';
    final int? brightness = bulb.brightness;
    return brightness == null ? state : '$state · $brightness';
  }
}
