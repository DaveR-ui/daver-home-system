import 'package:flutter/material.dart';

import '../hub/hub_status_controller.dart';
import '../hub_status.dart';
import '../surfaces/light_entity.dart';
import 'bulb_detail_screen.dart';
import 'switch_mirror_screen.dart';

/// The rooms/devices list: every `light.*`/`switch.*` entity the hub exposes,
/// grouped by room, with a hub-health card on top.
///
/// Render-only: each row reads the controller's cache and live state, and only
/// a bulb row opens a write surface. Home Assistant stays the authority
/// (ADR-0005).
class RoomsDevicesScreen extends StatelessWidget {
  const RoomsDevicesScreen({super.key, required this.controller});

  /// The app's reachability and render cache, listened to for live updates.
  final HubStatusController controller;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (BuildContext context, Widget? child) {
        final List<RoomSection> sections = sectionsFor(controller.entities);
        return ListView(
          padding: const EdgeInsets.all(16),
          children: <Widget>[
            _HubHealthCard(status: controller.status),
            const SizedBox(height: 16),
            if (sections.isEmpty)
              Text(
                'No bulb or switch entities yet.',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            for (final RoomSection section in sections) ...<Widget>[
              _RoomHeader(room: section.room),
              for (final LightEntity bulb in section.bulbs)
                _BulbRow(controller: controller, entity: bulb),
              for (final LightEntity sw in section.switches)
                _SwitchRow(controller: controller, entity: sw),
            ],
          ],
        );
      },
    );
  }
}

/// The hub-health card: the connected affirmation only.
///
/// The always-on status banner directly above the list already owns every
/// disconnected copy (connecting / hub unavailable / phone offline), so this
/// card renders nothing in those states — printing the same message on both
/// surfaces at once was finding #13. The banner owns the disconnected states;
/// this card owns only the connected affirmation the banner never shows.
class _HubHealthCard extends StatelessWidget {
  const _HubHealthCard({required this.status});

  /// Null means connected, matching [HubStatusController.status].
  final HubStatus? status;

  @override
  Widget build(BuildContext context) {
    // A non-null status is a disconnected state: the banner owns that copy, so
    // the card stays out of the way rather than repeating it.
    if (status != null) {
      return const SizedBox.shrink();
    }
    return const Card(
      child: ListTile(
        leading: Icon(Icons.cloud_done),
        title: Text('Hub connected'),
        subtitle: Text('Live state on.'),
      ),
    );
  }
}

class _RoomHeader extends StatelessWidget {
  const _RoomHeader({required this.room});

  final String room;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 16, 0, 4),
      child: Text(room, style: Theme.of(context).textTheme.titleMedium),
    );
  }
}

/// A bulb row: tapping it opens the write surface. The trailing indicator shows
/// while an accepted command awaits confirmation.
class _BulbRow extends StatelessWidget {
  const _BulbRow({required this.controller, required this.entity});

  final HubStatusController controller;
  final LightEntity entity;

  @override
  Widget build(BuildContext context) {
    final bool pending = controller.isPending(entity.entityId);
    return ListTile(
      title: Text(entity.device),
      subtitle: Text(_bulbSubtitle(entity)),
      trailing: pending
          ? const Icon(Icons.hourglass_empty)
          : const Icon(Icons.chevron_right),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => BulbDetailScreen(
            controller: controller,
            entityId: entity.entityId,
          ),
        ),
      ),
    );
  }

  static String _bulbSubtitle(LightEntity entity) {
    final String state = entity.isOn ? 'on' : 'off';
    final int? brightness = entity.brightness;
    return brightness == null ? state : '$state · $brightness';
  }
}

/// A switch row: tapping it opens the status-only mirror. It never becomes a
/// second write path to the bulbs its automation drives.
class _SwitchRow extends StatelessWidget {
  const _SwitchRow({required this.controller, required this.entity});

  final HubStatusController controller;
  final LightEntity entity;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Text(entity.device),
      subtitle: const Text('switch · status'),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => SwitchMirrorScreen(
            controller: controller,
            entityId: entity.entityId,
          ),
        ),
      ),
    );
  }
}
