import 'dart:async';

import 'package:daver_home/hub/hub_client.dart';
import 'package:daver_home/hub/hub_status_controller.dart';
import 'package:daver_home/hub/light_command.dart';
import 'package:daver_home/hub/light_command_client.dart';
import 'package:daver_home/hub/live_state_client.dart';
import 'package:daver_home/hub/token_store.dart';
import 'package:daver_home/ui/bulb_detail_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A command client that records every command, with an optional gate so a test
/// can hold a command pending.
class _FakeCommandClient implements LightCommandClient {
  final List<LightCommand> sent = <LightCommand>[];
  Completer<void>? gate;

  @override
  Future<void> sendLightCommand(LightCommand command) async {
    sent.add(command);
    if (gate != null) {
      await gate!.future;
    }
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

/// A live-state source the test drives directly through its status stream.
class _FakeLiveState implements LiveStateClient {
  final StreamController<EntityStateEvent> _events =
      StreamController<EntityStateEvent>.broadcast();
  final StreamController<LiveStatus> _status =
      StreamController<LiveStatus>.broadcast();

  @override
  Stream<EntityStateEvent> get events => _events.stream;

  @override
  Stream<LiveStatus> get status => _status.stream;

  @override
  void setTrackedEntities(Iterable<String> entityIds) {}

  @override
  Future<void> start() async {}

  @override
  Future<void> stop() async {}

  void pushStatus(LiveStatus status) => _status.add(status);
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

const EntitySnapshot _bulb = EntitySnapshot(
  entityId: 'light.kitchen_ceiling',
  state: 'on',
  attributes: <String, dynamic>{
    'brightness': 180,
    'rgb_color': <int>[255, 255, 255],
  },
);

Widget _host(HubStatusController controller) => MaterialApp(
      home: BulbDetailScreen(
        controller: controller,
        entityId: 'light.kitchen_ceiling',
      ),
    );

/// Lets a shown SnackBar's auto-dismiss timer fire, so no timer is left pending.
Future<void> _drainSnackBar(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 4));
  await tester.pumpAndSettle();
}

void main() {
  late _FakeCommandClient command;
  late _FakeHubClient hub;

  setUp(() {
    command = _FakeCommandClient();
    hub = _FakeHubClient()..states = const <EntitySnapshot>[_bulb];
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

  testWidgets('turn off sends a turn_off command', (WidgetTester tester) async {
    final HubStatusController c = await connected();
    addTearDown(c.dispose);

    await tester.pumpWidget(_host(c));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Turn off'));
    await tester.pumpAndSettle();

    expect(command.sent.single.entityId, 'light.kitchen_ceiling');
    expect(command.sent.single.service, LightService.turnOff);
    expect(find.text('Command sent'), findsOneWidget);
    await _drainSnackBar(tester);
  });

  testWidgets('turn on keeps the current brightness', (WidgetTester tester) async {
    final HubStatusController c = await connected();
    addTearDown(c.dispose);

    await tester.pumpWidget(_host(c));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Turn on'));
    await tester.pumpAndSettle();

    expect(command.sent.single.service, LightService.turnOn);
    expect(command.sent.single.brightness, 180);
    await _drainSnackBar(tester);
  });

  testWidgets('toggle sends a toggle command', (WidgetTester tester) async {
    final HubStatusController c = await connected();
    addTearDown(c.dispose);

    await tester.pumpWidget(_host(c));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Toggle'));
    await tester.pumpAndSettle();

    expect(command.sent.single.service, LightService.toggle);
    await _drainSnackBar(tester);
  });

  testWidgets('a colour swatch sends a turn_on with rgb_color',
      (WidgetTester tester) async {
    final HubStatusController c = await connected();
    addTearDown(c.dispose);

    await tester.pumpWidget(_host(c));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Red'));
    await tester.pumpAndSettle();

    expect(command.sent.single.service, LightService.turnOn);
    expect(command.sent.single.rgbColor, <int>[255, 0, 0]);
    await _drainSnackBar(tester);
  });

  testWidgets('the brightness slider sends a turn_on with a brightness',
      (WidgetTester tester) async {
    final HubStatusController c = await connected();
    addTearDown(c.dispose);

    await tester.pumpWidget(_host(c));
    await tester.pumpAndSettle();

    await tester.drag(find.byType(Slider), const Offset(50, 0));
    await tester.pumpAndSettle();

    expect(command.sent.single.service, LightService.turnOn);
    expect(command.sent.single.brightness, isNotNull);
    await _drainSnackBar(tester);
  });

  testWidgets('controls are disabled and the refusal line shows when the hub is down',
      (WidgetTester tester) async {
    final _FakeLiveState live = _FakeLiveState();
    final HubStatusController c = HubStatusController(
      client: hub,
      tokens: _FakeTokenStore('tok'),
      command: command,
      liveState: live,
    );
    addTearDown(c.dispose);
    await c.connect();

    // The hub drops out after the snapshot was cached.
    live.pushStatus(LiveStatus.hubUnavailable);
    await tester.pump();

    await tester.pumpWidget(_host(c));
    await tester.pumpAndSettle();

    expect(
      find.text('Hub unavailable — commands are refused until the hub is '
          'reachable.'),
      findsOneWidget,
    );

    final FilledButton off = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Turn off'),
    );
    expect(off.onPressed, isNull);

    final Slider slider = tester.widget<Slider>(find.byType(Slider));
    expect(slider.onChanged, isNull);
    expect(slider.onChangeEnd, isNull);

    await tester.tap(find.text('Turn off'), warnIfMissed: false);
    await tester.pump();
    expect(command.sent, isEmpty);
  });

  testWidgets('a pending command shows the pending indicator',
      (WidgetTester tester) async {
    final _FakeLiveState live = _FakeLiveState();
    final HubStatusController c = HubStatusController(
      client: hub,
      tokens: _FakeTokenStore('tok'),
      command: command,
      liveState: live,
      // A short confirmation deadline so the armed timer fires within the drain
      // instead of leaking past the end of the widget test.
      confirmTimeout: const Duration(milliseconds: 100),
    );
    addTearDown(c.dispose);
    await c.connect();

    command.gate = Completer<void>();
    await tester.pumpWidget(_host(c));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Turn off'));
    await tester.pump();

    expect(find.byIcon(Icons.hourglass_empty), findsOneWidget);

    command.gate!.complete();
    await tester.pumpAndSettle();
    await _drainSnackBar(tester);
  });

  testWidgets('controls are disabled while a command awaits confirmation',
      (WidgetTester tester) async {
    final _FakeLiveState live = _FakeLiveState();
    final HubStatusController c = HubStatusController(
      client: hub,
      tokens: _FakeTokenStore('tok'),
      command: command,
      liveState: live,
      // A short confirmation deadline so the armed timer fires within the drain
      // instead of leaking past the end of the widget test.
      confirmTimeout: const Duration(milliseconds: 100),
    );
    addTearDown(c.dispose);
    await c.connect();

    // A gate holds the command in flight so the pending state stays observable.
    command.gate = Completer<void>();
    await tester.pumpWidget(_host(c));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Turn off'));
    await tester.pump();

    // The hourglass marks the accepted-but-unconfirmed command...
    expect(find.byIcon(Icons.hourglass_empty), findsOneWidget);

    // ...and every write control is disabled, so a rapid second tap cannot
    // race it (the controller also refuses it as `busy`).
    for (final String label in <String>['Turn on', 'Turn off', 'Toggle']) {
      final FilledButton button = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, label),
      );
      expect(button.onPressed, isNull, reason: '$label is disabled');
    }

    final Slider slider = tester.widget<Slider>(find.byType(Slider));
    expect(slider.onChanged, isNull);
    expect(slider.onChangeEnd, isNull);

    for (final String label in <String>[
      'White',
      'Warm',
      'Red',
      'Green',
      'Blue',
    ]) {
      final InkWell swatch = tester.widget<InkWell>(
        find.descendant(
          of: find.byTooltip(label),
          matching: find.byType(InkWell),
        ),
      );
      expect(swatch.onTap, isNull, reason: '$label swatch is disabled');
    }

    // Releasing the gate lets the command finish, then the snack bar drains.
    command.gate!.complete();
    await tester.pumpAndSettle();
    await _drainSnackBar(tester);
  });

  testWidgets('an unknown entity shows an empty state', (WidgetTester tester) async {
    final HubStatusController c = await connected();
    addTearDown(c.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: BulbDetailScreen(controller: c, entityId: 'light.missing'),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Entity not found.'), findsOneWidget);
    expect(find.byType(Slider), findsNothing);
  });
}
