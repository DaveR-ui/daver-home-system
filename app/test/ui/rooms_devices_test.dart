import 'package:daver_home/hub/hub_client.dart';
import 'package:daver_home/hub/hub_status_controller.dart';
import 'package:daver_home/hub/token_store.dart';
import 'package:daver_home/surfaces/light_entity.dart';
import 'package:daver_home/ui/bulb_detail_screen.dart';
import 'package:daver_home/ui/rooms_devices_screen.dart';
import 'package:daver_home/ui/switch_mirror_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A hub whose probe passes and whose snapshot is scripted.
class _FakeHubClient implements HubClient {
  List<EntitySnapshot> states = const <EntitySnapshot>[];
  Exception? probeError;

  @override
  Future<bool> probeHub() async {
    if (probeError != null) {
      throw probeError!;
    }
    return true;
  }

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

List<EntitySnapshot> _sampleStates() => <EntitySnapshot>[
      const EntitySnapshot(
        entityId: 'light.kitchen_ceiling',
        state: 'on',
        attributes: <String, dynamic>{'brightness': 180},
      ),
      const EntitySnapshot(
        entityId: 'light.kitchen_counter',
        state: 'off',
        attributes: <String, dynamic>{},
      ),
      const EntitySnapshot(
        entityId: 'switch.living_room_fan',
        state: 'on',
        attributes: <String, dynamic>{},
      ),
      const EntitySnapshot(
        entityId: 'sensor.kitchen_temp',
        state: '21',
        attributes: <String, dynamic>{},
      ),
    ];

Future<HubStatusController> _connected(_FakeHubClient hub) async {
  final HubStatusController c = HubStatusController(
    client: hub,
    tokens: _FakeTokenStore('tok'),
  );
  await c.connect();
  return c;
}

Widget _host(HubStatusController controller) => MaterialApp(
      home: Scaffold(body: RoomsDevicesScreen(controller: controller)),
    );

void main() {
  testWidgets('renders bulbs and switches grouped by room, sensors filtered out',
      (WidgetTester tester) async {
    final _FakeHubClient hub = _FakeHubClient()..states = _sampleStates();
    final HubStatusController c = await _connected(hub);
    addTearDown(c.dispose);

    await tester.pumpWidget(_host(c));
    await tester.pumpAndSettle();

    // Room headers, bulbs, and the switch all render.
    expect(find.text('Kitchen'), findsOneWidget);
    expect(find.text('Living'), findsOneWidget);
    expect(find.text('Ceiling'), findsOneWidget);
    expect(find.text('Counter'), findsOneWidget);
    expect(find.text('Room Fan'), findsOneWidget);
    expect(find.text('switch · status'), findsOneWidget);

    // The bulb subtitle carries the state plus its brightness.
    expect(find.text('on · 180'), findsOneWidget);
    expect(find.text('off'), findsOneWidget);

    // A sensor is not a light/switch entity, so it is filtered out.
    expect(find.text('Temp'), findsNothing);
  });

  testWidgets('an empty snapshot shows the empty-state line',
      (WidgetTester tester) async {
    final _FakeHubClient hub = _FakeHubClient();
    final HubStatusController c = await _connected(hub);
    addTearDown(c.dispose);

    await tester.pumpWidget(_host(c));
    await tester.pumpAndSettle();

    expect(find.text('No bulb or switch entities yet.'), findsOneWidget);
  });

  testWidgets('tapping a bulb opens the bulb detail screen',
      (WidgetTester tester) async {
    final _FakeHubClient hub = _FakeHubClient()..states = _sampleStates();
    final HubStatusController c = await _connected(hub);
    addTearDown(c.dispose);

    await tester.pumpWidget(_host(c));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Ceiling'));
    await tester.pumpAndSettle();

    expect(find.byType(BulbDetailScreen), findsOneWidget);
  });

  testWidgets('tapping a switch opens the status-only mirror',
      (WidgetTester tester) async {
    final _FakeHubClient hub = _FakeHubClient()..states = _sampleStates();
    final HubStatusController c = await _connected(hub);
    addTearDown(c.dispose);

    await tester.pumpWidget(_host(c));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Room Fan'));
    await tester.pumpAndSettle();

    expect(find.byType(SwitchMirrorScreen), findsOneWidget);
  });

  testWidgets('the hub health card says connected when the hub answers',
      (WidgetTester tester) async {
    final _FakeHubClient hub = _FakeHubClient()..states = _sampleStates();
    final HubStatusController c = await _connected(hub);
    addTearDown(c.dispose);

    await tester.pumpWidget(_host(c));
    await tester.pumpAndSettle();

    expect(find.text('Hub connected'), findsOneWidget);
    expect(find.byIcon(Icons.cloud_done), findsOneWidget);
  });

  testWidgets(
      'the health card stays out of the way while the banner owns the '
      'disconnected copy', (WidgetTester tester) async {
    final _FakeHubClient hub = _FakeHubClient();
    final HubStatusController c = HubStatusController(
      client: hub,
      tokens: _FakeTokenStore('tok'),
    );
    addTearDown(c.dispose);

    // No connect(): the controller is still finding the hub. The banner above
    // the list owns this copy, so the health card renders nothing.
    await tester.pumpWidget(_host(c));
    await tester.pump();

    expect(find.text('Connecting to the hub'), findsNothing);
    expect(find.byIcon(Icons.sync), findsNothing);

    // The list itself still renders.
    expect(find.byType(RoomsDevicesScreen), findsOneWidget);
    expect(find.text('No bulb or switch entities yet.'), findsOneWidget);
  });

  testWidgets(
      'the health card hides on a failed probe while the banner owns the '
      'disconnected copy', (WidgetTester tester) async {
    final _FakeHubClient hub = _FakeHubClient()
      ..probeError = const HubUnavailableException();
    final HubStatusController c = await _connected(hub);
    addTearDown(c.dispose);

    await tester.pumpWidget(_host(c));
    await tester.pumpAndSettle();

    expect(find.text('Hub unavailable'), findsNothing);
    expect(find.text('State may be stale; commands are refused.'), findsNothing);
    expect(find.byIcon(Icons.cloud_off), findsNothing);

    // The list itself still renders.
    expect(find.byType(RoomsDevicesScreen), findsOneWidget);
    expect(find.text('No bulb or switch entities yet.'), findsOneWidget);
  });

  testWidgets(
      'with no token the health card hides while the banner owns the '
      'disconnected copy', (WidgetTester tester) async {
    final _FakeHubClient hub = _FakeHubClient()..states = _sampleStates();
    final HubStatusController c = HubStatusController(
      client: hub,
      tokens: _FakeTokenStore(),
    );
    addTearDown(c.dispose);
    await c.connect();

    await tester.pumpWidget(_host(c));
    await tester.pumpAndSettle();

    expect(find.text('Hub unavailable'), findsNothing);

    // The list itself still renders. Without a token the snapshot is never
    // fetched, so the list shows its empty state, not a stale entity row.
    expect(find.byType(RoomsDevicesScreen), findsOneWidget);
    expect(find.text('No bulb or switch entities yet.'), findsOneWidget);
  });

  test('sectionsFor is reachable through the screen contract', () {
    final List<RoomSection> sections = sectionsFor(_sampleStates());
    expect(sections, hasLength(2));
  });
}
