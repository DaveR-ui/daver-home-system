import 'package:daver_home/hub/hub_client.dart';
import 'package:daver_home/hub/hub_status_controller.dart';
import 'package:daver_home/hub/light_command.dart';
import 'package:daver_home/hub/light_command_client.dart';
import 'package:daver_home/hub/token_store.dart';
import 'package:daver_home/ui/switch_mirror_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Records every command, so a test can prove the mirror never sends one.
class _FakeCommandClient implements LightCommandClient {
  final List<LightCommand> sent = <LightCommand>[];

  @override
  Future<void> sendLightCommand(LightCommand command) async {
    sent.add(command);
  }
}

class _FakeHubClient implements HubClient {
  List<EntitySnapshot> states = const <EntitySnapshot>[];

  @override
  Future<bool> probeHub() async => true;

  @override
  Future<List<EntitySnapshot>> fetchStates() async => states;

  @override
  Future<EntitySnapshot> fetchEntity(String entityId) async {
    for (final EntitySnapshot snapshot in states) {
      if (snapshot.entityId == entityId) {
        return snapshot;
      }
    }
    throw const HubUnavailableException();
  }
}

class _FakeTokenStore implements TokenStore {
  _FakeTokenStore([this.token]);

  String? token;

  @override
  Future<String?> readToken() async => token;

  @override
  Future<void> writeToken(String token) async => this.token = token;

  @override
  Future<void> clearToken() async => token = null;
}

const List<EntitySnapshot> _states = <EntitySnapshot>[
  EntitySnapshot(
    entityId: 'switch.living_room_fan',
    state: 'on',
    attributes: <String, dynamic>{},
  ),
  EntitySnapshot(
    entityId: 'light.living_room_ceiling',
    state: 'on',
    attributes: <String, dynamic>{'brightness': 100},
  ),
  EntitySnapshot(
    entityId: 'light.kitchen_ceiling',
    state: 'off',
    attributes: <String, dynamic>{},
  ),
];

Widget _host(HubStatusController controller) => MaterialApp(
      home: SwitchMirrorScreen(
        controller: controller,
        entityId: 'switch.living_room_fan',
      ),
    );

void main() {
  late _FakeCommandClient command;
  late _FakeHubClient hub;

  setUp(() {
    command = _FakeCommandClient();
    hub = _FakeHubClient()..states = _states;
  });

  Future<HubStatusController> connected() async {
    final HubStatusController c = HubStatusController(
      client: hub,
      tokens: _FakeTokenStore('tok'),
      command: command,
    );
    await c.connect();
    return c;
  }

  testWidgets('shows the switch state read-only and its linked bulbs',
      (WidgetTester tester) async {
    final HubStatusController c = await connected();
    addTearDown(c.dispose);

    await tester.pumpWidget(_host(c));
    await tester.pumpAndSettle();

    // The switch is rendered read-only.
    expect(find.text('Room Fan'), findsOneWidget);
    expect(find.text('State: on (read-only)'), findsOneWidget);

    // The same-room bulb is listed with its state and brightness...
    expect(find.text('Room Ceiling'), findsOneWidget);
    expect(find.text('on · 100'), findsOneWidget);
    // ...but a bulb in another room is not part of this automation.
    expect(find.text('Kitchen Ceiling'), findsNothing);

    expect(
      find.text(
        "This switch's Home Assistant automation drives these bulbs. "
        'Status only — control each bulb from its own screen.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('exposes no write path: no controls and no command is ever sent',
      (WidgetTester tester) async {
    final HubStatusController c = await connected();
    addTearDown(c.dispose);

    await tester.pumpWidget(_host(c));
    await tester.pumpAndSettle();

    // No toggle/button/slider surface exists on a status mirror.
    expect(find.byType(FilledButton), findsNothing);
    expect(find.byType(Slider), findsNothing);
    expect(find.byType(Switch), findsNothing);

    // Interacting with the read-only bulb row still sends nothing.
    await tester.tap(find.text('Room Ceiling'));
    await tester.pumpAndSettle();

    expect(command.sent, isEmpty);
  });

  testWidgets('an unknown switch shows an empty state',
      (WidgetTester tester) async {
    final HubStatusController c = await connected();
    addTearDown(c.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: SwitchMirrorScreen(controller: c, entityId: 'switch.missing'),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Entity not found.'), findsOneWidget);
  });
}
