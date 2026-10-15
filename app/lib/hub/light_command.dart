/// The Home Assistant light services the app is allowed to call.
///
/// These map onto `POST /api/services/light/<segment>`; Home Assistant stays the
/// single state authority (ADR-0005), so a command is a request to the
/// authority, never a device write.
enum LightService {
  /// `turn_on` — switch the bulb on, optionally at a brightness or colour.
  turnOn,

  /// `turn_off` — switch the bulb off.
  turnOff,

  /// `toggle` — let Home Assistant invert the bulb's current state.
  toggle,
}

/// One light-service call to Home Assistant.
///
/// The only write path the app has: it is handed to a `LightCommandClient`, and
/// the transport is Home Assistant's `POST /api/services/light/*`. The app never
/// writes to a device, MQTT, or the Tuya LAN directly (ADR-0005).
class LightCommand {
  const LightCommand({
    required this.entityId,
    required this.service,
    this.brightness,
    this.rgbColor,
  });

  /// The target entity, e.g. `light.kitchen_ceiling`.
  final String entityId;

  /// Which light service to call.
  final LightService service;

  /// Home Assistant brightness `0..255`, when the command sets a level.
  final int? brightness;

  /// `[r, g, b]`, when the command sets a colour.
  final List<int>? rgbColor;

  /// The `POST /api/services/light/<segment>` path segment for [service].
  String get serviceSegment => switch (service) {
        LightService.turnOn => 'turn_on',
        LightService.turnOff => 'turn_off',
        LightService.toggle => 'toggle',
      };
}
