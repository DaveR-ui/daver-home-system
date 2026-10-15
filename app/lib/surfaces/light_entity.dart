import '../hub/hub_client.dart';

/// A Home Assistant light or switch entity, parsed for display.
///
/// Entity ids follow `light.<room>_<device>` / `switch.<room>_<device>`: the
/// domain is everything before the first `.`; the room is the run up to the
/// first `_`; the device is the remainder. Both halves are title-cased for
/// display. Pure Dart with no Flutter import, so it is unit-testable without a
/// widget harness.
class LightEntity {
  const LightEntity({
    required this.snapshot,
    required this.room,
    required this.device,
  });

  /// Parses [snapshot]'s `entity_id` into a display [room] and [device].
  factory LightEntity.from(EntitySnapshot snapshot) {
    final String entityId = snapshot.entityId;
    final int dot = entityId.indexOf('.');
    final String rest = dot >= 0 ? entityId.substring(dot + 1) : entityId;
    final int underscore = rest.indexOf('_');
    final String rawRoom = underscore >= 0 ? rest.substring(0, underscore) : rest;
    final String rawDevice =
        underscore >= 0 ? rest.substring(underscore + 1) : '';
    return LightEntity(
      snapshot: snapshot,
      room: _titleCase(rawRoom),
      device: _titleCase(rawDevice),
    );
  }

  /// The cached entity row this view is built from.
  final EntitySnapshot snapshot;

  /// The display room, e.g. `Kitchen`.
  final String room;

  /// The display device, e.g. `Ceiling`.
  final String device;

  String get entityId => snapshot.entityId;

  /// True for a `light.*` entity — the app's controllable write target.
  bool get isBulb => entityId.startsWith('light.');

  /// True for a `switch.*` entity — status only, never a write target.
  bool get isSwitch => entityId.startsWith('switch.');

  bool get isOn => snapshot.state == 'on';

  /// HA brightness as an int, or null when the entity does not report one.
  int? get brightness {
    final Object? value = snapshot.attributes['brightness'];
    return value is int ? value : (value is num ? value.round() : null);
  }

  /// True when the entity reports a colour the app can set.
  bool get hasColour => snapshot.attributes.containsKey('rgb_color');

  static String _titleCase(String value) {
    if (value.isEmpty) {
      return value;
    }
    return value
        .split(RegExp(r'[_-]'))
        .map((String word) => word.isEmpty
            ? word
            : '${word[0].toUpperCase()}${word.substring(1)}')
        .join(' ');
  }
}

/// One room's bulbs and switches, ready to render.
class RoomSection {
  const RoomSection({
    required this.room,
    required this.bulbs,
    required this.switches,
  });

  /// The display room name.
  final String room;

  /// The room's `light.*` entities, sorted by entity id.
  final List<LightEntity> bulbs;

  /// The room's `switch.*` entities, sorted by entity id.
  final List<LightEntity> switches;
}

/// Groups [entities] into room sections.
///
/// Only `light.*` and `switch.*` entities are kept. Rooms sort alphabetically;
/// within a room, bulbs come before switches, each list sorted by entity id.
List<RoomSection> sectionsFor(List<EntitySnapshot> entities) {
  final Map<String, List<LightEntity>> byRoom = <String, List<LightEntity>>{};
  for (final EntitySnapshot snapshot in entities) {
    final LightEntity entity = LightEntity.from(snapshot);
    if (!entity.isBulb && !entity.isSwitch) {
      continue;
    }
    byRoom.putIfAbsent(entity.room, () => <LightEntity>[]).add(entity);
  }

  final List<String> rooms = byRoom.keys.toList()..sort();
  return <RoomSection>[
    for (final String room in rooms)
      RoomSection(
        room: room,
        bulbs: _sorted(byRoom[room]!.where((LightEntity e) => e.isBulb)),
        switches: _sorted(byRoom[room]!.where((LightEntity e) => e.isSwitch)),
      ),
  ];
}

/// The `light.*` entities in the same room as [sw], sorted by entity id.
///
/// This is the switch's automation targets, shown read-only: the switch-mirror
/// surface exposes no write path of its own (ADR-0005).
List<LightEntity> linkedBulbsFor(
  LightEntity sw,
  List<EntitySnapshot> entities,
) {
  return _sorted(
    entities
        .map(LightEntity.from)
        .where((LightEntity e) => e.isBulb && e.room == sw.room),
  );
}

List<LightEntity> _sorted(Iterable<LightEntity> entities) {
  final List<LightEntity> list = entities.toList()
    ..sort((LightEntity a, LightEntity b) => a.entityId.compareTo(b.entityId));
  return list;
}
