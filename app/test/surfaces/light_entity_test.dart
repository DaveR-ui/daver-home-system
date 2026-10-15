import 'package:daver_home/hub/hub_client.dart';
import 'package:daver_home/surfaces/light_entity.dart';
import 'package:flutter_test/flutter_test.dart';

EntitySnapshot _snapshot(
  String entityId, {
  String state = 'on',
  Map<String, dynamic> attributes = const <String, dynamic>{},
}) =>
    EntitySnapshot(entityId: entityId, state: state, attributes: attributes);

void main() {
  group('LightEntity.from', () {
    test('splits a light id into a title-cased room and device', () {
      final LightEntity entity =
          LightEntity.from(_snapshot('light.kitchen_ceiling'));

      expect(entity.entityId, 'light.kitchen_ceiling');
      expect(entity.room, 'Kitchen');
      expect(entity.device, 'Ceiling');
      expect(entity.isBulb, isTrue);
      expect(entity.isSwitch, isFalse);
    });

    test('title-cases a multi-word room and device on _ and -', () {
      final LightEntity entity =
          LightEntity.from(_snapshot('light.living_room_ceiling'));

      expect(entity.room, 'Living');
      expect(entity.device, 'Room Ceiling');
    });

    test('a switch id has no bulb flag', () {
      final LightEntity entity =
          LightEntity.from(_snapshot('switch.living_room_fan'));

      expect(entity.isSwitch, isTrue);
      expect(entity.isBulb, isFalse);
      expect(entity.room, 'Living');
      expect(entity.device, 'Room Fan');
    });

    test('an id with no underscore leaves the device empty', () {
      final LightEntity entity = LightEntity.from(_snapshot('light.kitchen'));

      expect(entity.room, 'Kitchen');
      expect(entity.device, '');
    });

    test('isOn reflects the state string', () {
      expect(
        LightEntity.from(_snapshot('light.a', state: 'on')).isOn,
        isTrue,
      );
      expect(
        LightEntity.from(_snapshot('light.a', state: 'off')).isOn,
        isFalse,
      );
    });

    test('brightness reads an int and rounds a double, null when absent', () {
      expect(
        LightEntity.from(
          _snapshot('light.a', attributes: <String, dynamic>{'brightness': 180}),
        ).brightness,
        180,
      );
      expect(
        LightEntity.from(
          _snapshot(
            'light.a',
            attributes: <String, dynamic>{'brightness': 180.6},
          ),
        ).brightness,
        181,
      );
      expect(LightEntity.from(_snapshot('light.a')).brightness, isNull);
    });

    test('hasColour is true only when rgb_color is present', () {
      expect(
        LightEntity.from(
          _snapshot('light.a', attributes: <String, dynamic>{
            'rgb_color': <int>[255, 0, 0],
          }),
        ).hasColour,
        isTrue,
      );
      expect(LightEntity.from(_snapshot('light.a')).hasColour, isFalse);
    });
  });

  group('sectionsFor', () {
    test('filters non light/switch entities and groups by room', () {
      final List<EntitySnapshot> entities = <EntitySnapshot>[
        _snapshot('light.kitchen_ceiling'),
        _snapshot('switch.living_room_fan'),
        _snapshot('sensor.kitchen_temp'),
        _snapshot('light.kitchen_counter'),
      ];

      final List<RoomSection> sections = sectionsFor(entities);

      expect(
        sections.map((RoomSection s) => s.room),
        <String>['Kitchen', 'Living'],
      );
      expect(
        sections.first.bulbs.map((LightEntity e) => e.entityId),
        <String>['light.kitchen_ceiling', 'light.kitchen_counter'],
      );
      expect(sections.first.switches, isEmpty);
      expect(
        sections.last.switches.map((LightEntity e) => e.entityId),
        <String>['switch.living_room_fan'],
      );
    });

    test('rooms sort alphabetically and bulbs come before switches', () {
      final List<EntitySnapshot> entities = <EntitySnapshot>[
        _snapshot('switch.kitchen_wall'),
        _snapshot('light.kitchen_ceiling'),
        _snapshot('light.bedroom_lamp'),
      ];

      final List<RoomSection> sections = sectionsFor(entities);

      expect(
        sections.map((RoomSection s) => s.room),
        <String>['Bedroom', 'Kitchen'],
      );
      // Within a room the bulbs list carries the switch too, so the render can
      // place bulbs above switches.
      expect(
        sections.last.bulbs.map((LightEntity e) => e.entityId),
        <String>['light.kitchen_ceiling'],
      );
      expect(
        sections.last.switches.map((LightEntity e) => e.entityId),
        <String>['switch.kitchen_wall'],
      );
    });

    test('an empty input yields no sections', () {
      expect(sectionsFor(const <EntitySnapshot>[]), isEmpty);
    });
  });

  group('linkedBulbsFor', () {
    test('returns same-room bulbs sorted by entity id', () {
      final List<EntitySnapshot> entities = <EntitySnapshot>[
        _snapshot('switch.living_room_fan'),
        _snapshot('light.living_room_ceiling'),
        _snapshot('light.living_room_floor'),
        _snapshot('light.kitchen_ceiling'),
      ];
      final LightEntity sw =
          LightEntity.from(_snapshot('switch.living_room_fan'));

      final List<LightEntity> bulbs = linkedBulbsFor(sw, entities);

      expect(
        bulbs.map((LightEntity e) => e.entityId),
        <String>['light.living_room_ceiling', 'light.living_room_floor'],
      );
    });
  });
}
