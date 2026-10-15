import 'dart:async';

import 'package:flutter/material.dart';

import '../hub/hub_client.dart';
import '../hub/hub_status_controller.dart';
import '../hub/light_command.dart';
import '../surfaces/light_entity.dart';

/// The bulb detail screen: on/off/toggle, brightness, and colour.
///
/// Every control builds a [LightCommand] and hands it to the controller, whose
/// only write path is Home Assistant's `POST /api/services/light/*` (ADR-0005).
/// When the hub is unreachable the controls are disabled and the controller
/// refuses the command rather than queueing it; while an accepted command
/// awaits confirmation they are disabled too, so a second tap cannot race it.
class BulbDetailScreen extends StatefulWidget {
  const BulbDetailScreen({
    super.key,
    required this.controller,
    required this.entityId,
  });

  /// The app's reachability, render cache, and write path.
  final HubStatusController controller;

  /// The `light.*` entity this screen controls.
  final String entityId;

  @override
  State<BulbDetailScreen> createState() => _BulbDetailScreenState();
}

class _BulbDetailScreenState extends State<BulbDetailScreen> {
  /// Colour presets sent as `rgb_color`, in HA's `0..255` space.
  static const Map<String, List<int>> _colourPresets = <String, List<int>>{
    'White': <int>[255, 255, 255],
    'Warm': <int>[255, 180, 107],
    'Red': <int>[255, 0, 0],
    'Green': <int>[0, 255, 0],
    'Blue': <int>[0, 64, 255],
  };

  /// The value under the brightness slider while dragging; null means use the
  /// entity's confirmed brightness.
  double? _dragBrightness;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Bulb')),
      body: AnimatedBuilder(
        animation: widget.controller,
        builder: (BuildContext context, Widget? child) {
          final LightEntity? entity = _findEntity();
          if (entity == null) {
            return const Center(child: Text('Entity not found.'));
          }
          return _buildBody(context, entity);
        },
      ),
    );
  }

  LightEntity? _findEntity() {
    for (final EntitySnapshot snapshot in widget.controller.entities) {
      if (snapshot.entityId == widget.entityId) {
        return LightEntity.from(snapshot);
      }
    }
    return null;
  }

  Widget _buildBody(BuildContext context, LightEntity entity) {
    final HubStatusController controller = widget.controller;
    final bool canSend = controller.canSendCommands;
    final bool pending = controller.isPending(entity.entityId);
    // While an accepted command awaits confirmation the controls are disabled,
    // so a rapid second tap cannot race the first; the controller also refuses
    // it as `busy`.
    final bool enabled = canSend && !pending;
    final bool supportsLevel = entity.brightness != null || entity.hasColour;
    final int effectiveBrightness =
        _dragBrightness?.round() ?? entity.brightness ?? 0;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: <Widget>[
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    '${entity.room} ${entity.device}',
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 4),
                  Text('State: ${entity.isOn ? 'on' : 'off'}'),
                  if (entity.brightness != null)
                    Text('Brightness: ${entity.brightness}'),
                ],
              ),
            ),
            if (pending) const Icon(Icons.hourglass_empty),
          ],
        ),
        const SizedBox(height: 16),
        if (!canSend)
          const Card(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'Hub unavailable — commands are refused until the hub is '
                'reachable.',
              ),
            ),
          ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            FilledButton(
              onPressed: enabled
                  ? () => _send(LightService.turnOn, brightness: entity.brightness)
                  : null,
              child: const Text('Turn on'),
            ),
            FilledButton(
              onPressed:
                  enabled ? () => _send(LightService.turnOff) : null,
              child: const Text('Turn off'),
            ),
            FilledButton(
              onPressed: enabled ? () => _send(LightService.toggle) : null,
              child: const Text('Toggle'),
            ),
          ],
        ),
        if (supportsLevel) ...<Widget>[
          const SizedBox(height: 16),
          Text('Brightness: $effectiveBrightness'),
          Slider(
            min: 0,
            max: 255,
            divisions: 255,
            value: effectiveBrightness.toDouble(),
            onChanged: enabled
                ? (double value) => setState(() => _dragBrightness = value)
                : null,
            onChangeEnd: enabled
                ? (double value) =>
                    _send(LightService.turnOn, brightness: value.round())
                : null,
          ),
        ],
        if (entity.hasColour) ...<Widget>[
          const SizedBox(height: 16),
          Text(
            'Colour',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 12,
            children: <Widget>[
              for (final MapEntry<String, List<int>> preset
                  in _colourPresets.entries)
                _ColourSwatch(
                  label: preset.key,
                  rgb: preset.value,
                  onTap: enabled
                      ? () => _send(LightService.turnOn, rgbColor: preset.value)
                      : null,
                ),
            ],
          ),
        ],
      ],
    );
  }

  /// Builds a [LightCommand] and dispatches it without blocking the tap.
  void _send(LightService service, {int? brightness, List<int>? rgbColor}) {
    final LightCommand command = LightCommand(
      entityId: widget.entityId,
      service: service,
      brightness: brightness,
      rgbColor: rgbColor,
    );
    unawaited(_dispatch(command));
  }

  Future<void> _dispatch(LightCommand command) async {
    final CommandOutcome outcome =
        await widget.controller.sendLightCommand(command);
    if (!mounted) {
      return;
    }
    final String message = switch (outcome) {
      CommandOutcome.sent => 'Command sent',
      CommandOutcome.refused => 'Hub unavailable — command not sent',
      CommandOutcome.needsToken => 'Re-enter your token',
      CommandOutcome.busy => 'A command is already in flight',
      CommandOutcome.failed => 'Command failed',
    };
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }
}

/// One preset colour swatch. Disabled (no-op) when the hub is down or a
/// command is already pending.
class _ColourSwatch extends StatelessWidget {
  const _ColourSwatch({
    required this.label,
    required this.rgb,
    required this.onTap,
  });

  final String label;
  final List<int> rgb;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final Color color = Color.fromARGB(255, rgb[0], rgb[1], rgb[2]);
    return Tooltip(
      message: label,
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: Border.all(color: Theme.of(context).colorScheme.outline),
          ),
        ),
      ),
    );
  }
}
