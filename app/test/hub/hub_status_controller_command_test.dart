import 'dart:async';

import 'package:daver_home/hub/hub_client.dart';
import 'package:daver_home/hub/hub_status_controller.dart';
import 'package:daver_home/hub/light_command.dart';
import 'package:daver_home/hub/light_command_client.dart';
import 'package:daver_home/hub/live_state_client.dart';
import 'package:daver_home/hub/token_store.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// A command client that records every command and can be scripted to fail.
///
/// [gate] holds every send in flight so a test can keep a command pending;
/// [gates] overrides it per entity so commands on different entities can be
/// released independently.
class _FakeCommandClient implements LightCommandClient {
  final List<LightCommand> sent = <LightCommand>[];
  Exception? error;
  Completer<void>? gate;
  final Map<String, Completer<void>> gates = <String, Completer<void>>{};

  @override
  Future<void> sendLightCommand(LightCommand command) async {
    sent.add(command);
    final Completer<void>? held = gates[command.entityId] ?? gate;
    if (held != null) {
      await held.future;
    }
    if (error != null) {
      throw error!;
    }
  }
}

/// A hub whose probe passes and whose snapshot/fetchEntity are scripted.
class _FakeHubClient implements HubClient {
  List<EntitySnapshot> states = const <EntitySnapshot>[];
  Exception? probeError;

  /// When set, [fetchEntity] throws it, so a test can drive a failed re-read.
  Exception? fetchEntityError;

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
    if (fetchEntityError != null) {
      throw fetchEntityError!;
    }
    for (final EntitySnapshot snapshot in states) {
      if (snapshot.entityId == entityId) {
        return snapshot;
      }
    }
    throw const HubUnavailableException();
  }
}

/// A live-state source the test drives directly through its broadcast streams.
class _FakeLiveState implements LiveStateClient {
  final StreamController<EntityStateEvent> _events =
      StreamController<EntityStateEvent>.broadcast();
  final StreamController<LiveStatus> _status =
      StreamController<LiveStatus>.broadcast();

  final List<String> tracked = <String>[];
  bool started = false;

  @override
  Stream<EntityStateEvent> get events => _events.stream;

  @override
  Stream<LiveStatus> get status => _status.stream;

  @override
  void setTrackedEntities(Iterable<String> entityIds) {
    tracked
      ..clear()
      ..addAll(entityIds);
  }

  @override
  Future<void> start() async => started = true;

  @override
  Future<void> stop() async {}

  void pushEvent(EntityStateEvent event) => _events.add(event);
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

void main() {
  late _FakeHubClient hub;
  late _FakeTokenStore tokens;
  late _FakeCommandClient command;

  HubStatusController controller({_FakeLiveState? live}) => HubStatusController(
        client: hub,
        tokens: tokens,
        liveState: live,
        command: command,
      );

  setUp(() {
    hub = _FakeHubClient();
    tokens = _FakeTokenStore('tok');
    command = _FakeCommandClient();
  });

  test('when not connected, a command is refused and nothing is sent',
      () async {
    // Never connected: the controller starts at `connecting`, so the authority
    // is unproven and the write must be refused rather than queued.
    final HubStatusController c = controller();
    addTearDown(c.dispose);

    final CommandOutcome outcome = await c.sendLightCommand(
      const LightCommand(entityId: 'light.a', service: LightService.turnOn),
    );

    expect(outcome, CommandOutcome.refused);
    expect(command.sent, isEmpty);
    expect(c.isPending('light.a'), isFalse);
  });

  test('turn_off sends the command and optimistically marks the row off',
      () async {
    hub.states = const <EntitySnapshot>[
      EntitySnapshot(entityId: 'light.a', state: 'on', attributes: {}),
    ];
    final _FakeLiveState live = _FakeLiveState();
    final HubStatusController c = controller(live: live);
    addTearDown(c.dispose);
    await c.connect();

    final CommandOutcome outcome = await c.sendLightCommand(
      const LightCommand(entityId: 'light.a', service: LightService.turnOff),
    );

    expect(outcome, CommandOutcome.sent);
    expect(command.sent.single.service, LightService.turnOff);
    expect(c.isPending('light.a'), isTrue);

    final EntitySnapshot row = c.entities.single;
    expect(row.state, 'off');
    // The optimistic row carries no timestamp, so the authoritative
    // state_changed always wins the ordering guard.
    expect(row.lastUpdated, isNull);
  });

  test('turn_on with brightness sets state on and the brightness attribute',
      () async {
    hub.states = const <EntitySnapshot>[
      EntitySnapshot(entityId: 'light.a', state: 'off', attributes: {}),
    ];
    final _FakeLiveState live = _FakeLiveState();
    final HubStatusController c = controller(live: live);
    addTearDown(c.dispose);
    await c.connect();

    await c.sendLightCommand(
      const LightCommand(
        entityId: 'light.a',
        service: LightService.turnOn,
        brightness: 180,
      ),
    );

    final EntitySnapshot row = c.entities.single;
    expect(row.state, 'on');
    expect(row.attributes['brightness'], 180);
    expect(row.lastUpdated, isNull);
  });

  test('toggle does not change the cached state optimistically', () async {
    hub.states = const <EntitySnapshot>[
      EntitySnapshot(entityId: 'light.a', state: 'off', attributes: {}),
    ];
    final _FakeLiveState live = _FakeLiveState();
    final HubStatusController c = controller(live: live);
    addTearDown(c.dispose);
    await c.connect();

    await c.sendLightCommand(
      const LightCommand(entityId: 'light.a', service: LightService.toggle),
    );

    // The result of a toggle is unknown until the authority confirms it.
    expect(c.entities.single.state, 'off');
    expect(c.isPending('light.a'), isTrue);
  });

  test('an authoritative state_changed clears pending and overrides the row',
      () async {
    hub.states = const <EntitySnapshot>[
      EntitySnapshot(entityId: 'light.a', state: 'on', attributes: {}),
    ];
    final _FakeLiveState live = _FakeLiveState();
    final HubStatusController c = controller(live: live);
    addTearDown(c.dispose);
    await c.connect();

    await c.sendLightCommand(
      const LightCommand(entityId: 'light.a', service: LightService.turnOff),
    );
    expect(c.entities.single.state, 'off');
    expect(c.isPending('light.a'), isTrue);

    // HA answers with the authoritative new state, overriding the optimism.
    live.pushEvent(const EntityStateEvent(
      entityId: 'light.a',
      state: 'on',
      attributes: <String, dynamic>{'brightness': 200},
    ));
    await pumpEventQueue();

    expect(c.isPending('light.a'), isFalse);
    expect(c.entities.single.state, 'on');
    expect(c.entities.single.attributes['brightness'], 200);
  });

  test('a rejected token gives needsToken and sets the re-auth flag', () async {
    hub.states = const <EntitySnapshot>[
      EntitySnapshot(entityId: 'light.a', state: 'on', attributes: {}),
    ];
    final _FakeLiveState live = _FakeLiveState();
    final HubStatusController c = controller(live: live);
    addTearDown(c.dispose);
    await c.connect();
    command.error = const TokenRejectedException();

    final CommandOutcome outcome = await c.sendLightCommand(
      const LightCommand(entityId: 'light.a', service: LightService.turnOn),
    );

    expect(outcome, CommandOutcome.needsToken);
    expect(c.needsToken, isTrue);
    expect(c.isPending('light.a'), isFalse);
  });

  test('a generic failure is failed, and the pending flag clears', () async {
    hub.states = const <EntitySnapshot>[
      EntitySnapshot(entityId: 'light.a', state: 'on', attributes: {}),
    ];
    final _FakeLiveState live = _FakeLiveState();
    final HubStatusController c = controller(live: live);
    addTearDown(c.dispose);
    await c.connect();
    command.error = const HubUnavailableException();

    final CommandOutcome outcome = await c.sendLightCommand(
      const LightCommand(entityId: 'light.a', service: LightService.turnOn),
    );

    expect(outcome, CommandOutcome.failed);
    expect(c.isPending('light.a'), isFalse);
    expect(c.entities.single.state, 'on');
  });

  test('without a live client a successful command is confirmed by a re-read',
      () async {
    // The hub's authoritative row still says `on`; the re-read must win over the
    // optimistic `off`, and the pending flag must clear.
    hub.states = const <EntitySnapshot>[
      EntitySnapshot(entityId: 'light.a', state: 'on', attributes: {}),
    ];
    final HubStatusController c = controller();
    addTearDown(c.dispose);
    await c.connect();

    final CommandOutcome outcome = await c.sendLightCommand(
      const LightCommand(entityId: 'light.a', service: LightService.turnOff),
    );

    expect(outcome, CommandOutcome.sent);
    expect(c.isPending('light.a'), isFalse);
    expect(c.entities.single.state, 'on');
  });

  test('canSendCommands needs both a connected hub and a write path', () async {
    hub.states = const <EntitySnapshot>[];
    final HubStatusController withCommand = controller();
    addTearDown(withCommand.dispose);
    expect(withCommand.canSendCommands, isFalse);
    await withCommand.connect();
    expect(withCommand.canSendCommands, isTrue);

    final HubStatusController withoutCommand =
        HubStatusController(client: hub, tokens: tokens);
    addTearDown(withoutCommand.dispose);
    await withoutCommand.connect();
    expect(withoutCommand.canSendCommands, isFalse);
  });

  test('turn_off keeps the cached brightness and colour attributes', () async {
    hub.states = <EntitySnapshot>[
      const EntitySnapshot(
        entityId: 'light.a',
        state: 'on',
        attributes: <String, dynamic>{
          'brightness': 180,
          'rgb_color': <int>[255, 255, 255],
        },
      ),
    ];
    final _FakeLiveState live = _FakeLiveState();
    final HubStatusController c = controller(live: live);
    addTearDown(c.dispose);
    await c.connect();

    await c.sendLightCommand(
      const LightCommand(entityId: 'light.a', service: LightService.turnOff),
    );

    // The merge keeps the attributes the command does not touch; a turn_off
    // must not wipe the cached brightness or colour.
    final EntitySnapshot row = c.entities.single;
    expect(row.state, 'off');
    expect(row.lastUpdated, isNull);
    expect(row.attributes['brightness'], 180);
    expect(row.attributes['rgb_color'], <int>[255, 255, 255]);
  });

  test('a brightness-only turn_on keeps the cached colour', () async {
    hub.states = <EntitySnapshot>[
      const EntitySnapshot(
        entityId: 'light.a',
        state: 'off',
        attributes: <String, dynamic>{'rgb_color': <int>[0, 64, 255]},
      ),
    ];
    final _FakeLiveState live = _FakeLiveState();
    final HubStatusController c = controller(live: live);
    addTearDown(c.dispose);
    await c.connect();

    await c.sendLightCommand(
      const LightCommand(
        entityId: 'light.a',
        service: LightService.turnOn,
        brightness: 100,
      ),
    );

    final EntitySnapshot row = c.entities.single;
    expect(row.state, 'on');
    expect(row.attributes['brightness'], 100);
    expect(row.attributes['rgb_color'], <int>[0, 64, 255]);
  });

  test('a colour-only turn_on keeps the cached brightness', () async {
    hub.states = <EntitySnapshot>[
      const EntitySnapshot(
        entityId: 'light.a',
        state: 'on',
        attributes: <String, dynamic>{'brightness': 180},
      ),
    ];
    final _FakeLiveState live = _FakeLiveState();
    final HubStatusController c = controller(live: live);
    addTearDown(c.dispose);
    await c.connect();

    await c.sendLightCommand(
      const LightCommand(
        entityId: 'light.a',
        service: LightService.turnOn,
        rgbColor: <int>[255, 0, 0],
      ),
    );

    final EntitySnapshot row = c.entities.single;
    expect(row.attributes['brightness'], 180);
    expect(row.attributes['rgb_color'], <int>[255, 0, 0]);
  });

  test('a cached rgb_color decoded as List<dynamic> is normalized to List<int>',
      () async {
    // HA's JSON decodes rgb_color as a List<dynamic>; the render cache must
    // keep the List<int> shape a command carries.
    hub.states = <EntitySnapshot>[
      const EntitySnapshot(
        entityId: 'light.a',
        state: 'off',
        attributes: <String, dynamic>{'rgb_color': <dynamic>[255, 0, 0]},
      ),
    ];
    final _FakeLiveState live = _FakeLiveState();
    final HubStatusController c = controller(live: live);
    addTearDown(c.dispose);
    await c.connect();

    await c.sendLightCommand(
      const LightCommand(
        entityId: 'light.a',
        service: LightService.turnOn,
        brightness: 50,
      ),
    );

    final EntitySnapshot row = c.entities.single;
    expect(row.attributes['rgb_color'], isA<List<int>>());
    expect(row.attributes['rgb_color'], <int>[255, 0, 0]);
  });

  test('an optimistic write never mutates the cached row in place', () async {
    hub.states = const <EntitySnapshot>[
      EntitySnapshot(
        entityId: 'light.a',
        state: 'on',
        attributes: <String, dynamic>{
          'brightness': 180,
          'rgb_color': <int>[255, 255, 255],
        },
      ),
    ];
    final _FakeLiveState live = _FakeLiveState();
    final HubStatusController c = controller(live: live);
    addTearDown(c.dispose);
    await c.connect();

    // The row the render already holds, with the map it was built from.
    final Map<String, dynamic> cachedAttributes = c.entities.single.attributes;

    await c.sendLightCommand(
      const LightCommand(
        entityId: 'light.a',
        service: LightService.turnOn,
        brightness: 100,
      ),
    );

    // The optimistic row is a copy, so the merge can only write the new row:
    // a live event or the render must never see its own map change under it.
    expect(
      cachedAttributes,
      <String, dynamic>{
        'brightness': 180,
        'rgb_color': <int>[255, 255, 255],
      },
    );
    expect(c.entities.single.attributes['brightness'], 100);
  });

  test('a second command for a pending entity is refused and sends nothing',
      () async {
    hub.states = const <EntitySnapshot>[
      EntitySnapshot(entityId: 'light.a', state: 'on', attributes: {}),
    ];
    final HubStatusController c = controller();
    addTearDown(c.dispose);
    await c.connect();

    command.gate = Completer<void>();
    final Future<CommandOutcome> first = c.sendLightCommand(
      const LightCommand(entityId: 'light.a', service: LightService.turnOff),
    );
    await pumpEventQueue();

    final CommandOutcome outcome = await c.sendLightCommand(
      const LightCommand(entityId: 'light.a', service: LightService.turnOff),
    );

    expect(outcome, CommandOutcome.busy);
    expect(command.sent, hasLength(1));
    expect(c.isPending('light.a'), isTrue);

    command.gate!.complete();
    await first;
    await pumpEventQueue();

    expect(c.isPending('light.a'), isFalse);
  });

  test('commands on different entities do not block each other', () async {
    hub.states = const <EntitySnapshot>[
      EntitySnapshot(entityId: 'light.a', state: 'on', attributes: {}),
      EntitySnapshot(entityId: 'light.b', state: 'on', attributes: {}),
    ];
    final HubStatusController c = controller();
    addTearDown(c.dispose);
    await c.connect();

    final Completer<void> gateA = Completer<void>();
    final Completer<void> gateB = Completer<void>();
    command.gates['light.a'] = gateA;
    command.gates['light.b'] = gateB;

    final Future<CommandOutcome> first = c.sendLightCommand(
      const LightCommand(entityId: 'light.a', service: LightService.turnOff),
    );
    final Future<CommandOutcome> second = c.sendLightCommand(
      const LightCommand(entityId: 'light.b', service: LightService.turnOff),
    );
    await pumpEventQueue();

    // The guard is per entity: both commands reached the client.
    expect(command.sent, hasLength(2));
    expect(c.isPending('light.a'), isTrue);
    expect(c.isPending('light.b'), isTrue);

    gateA.complete();
    await first;
    await pumpEventQueue();
    expect(c.isPending('light.a'), isFalse);
    expect(c.isPending('light.b'), isTrue);

    gateB.complete();
    await second;
    await pumpEventQueue();
    expect(c.isPending('light.b'), isFalse);
  });

  testWidgets('a confirmation timeout clears the pending flag after a no-op command',
      (WidgetTester tester) async {
    // HA accepts the write but emits no state_changed: the deadline must drive
    // the same render-only re-read the REST-only path uses.
    final DateTime authoritative = DateTime.utc(2026, 1, 1);
    hub.states = <EntitySnapshot>[
      EntitySnapshot(
        entityId: 'light.a',
        state: 'on',
        attributes: const <String, dynamic>{'brightness': 180},
        lastUpdated: authoritative,
      ),
    ];
    final _FakeLiveState live = _FakeLiveState();
    final HubStatusController c = controller(live: live);
    addTearDown(c.dispose);
    await tester.pumpWidget(const SizedBox());
    await c.connect();

    final CommandOutcome outcome = await c.sendLightCommand(
      const LightCommand(entityId: 'light.a', service: LightService.turnOff),
    );
    expect(outcome, CommandOutcome.sent);
    expect(c.isPending('light.a'), isTrue);
    expect(c.entities.single.state, 'off');

    await tester.pump(const Duration(seconds: 6));
    await tester.pump();

    expect(c.isPending('light.a'), isFalse);
    final EntitySnapshot row = c.entities.single;
    expect(row.state, 'on');
    expect(row.lastUpdated, isNotNull);
  });

  testWidgets(
      'a failed re-read still clears the pending flag and leaves the '
      'optimistic row untouched', (WidgetTester tester) async {
    hub.states = const <EntitySnapshot>[
      EntitySnapshot(
        entityId: 'light.a',
        state: 'on',
        attributes: <String, dynamic>{},
      ),
    ];
    final _FakeLiveState live = _FakeLiveState();
    final HubStatusController c = controller(live: live);
    addTearDown(c.dispose);
    await tester.pumpWidget(const SizedBox());
    await c.connect();
    hub.fetchEntityError = const HubUnavailableException();

    await c.sendLightCommand(
      const LightCommand(entityId: 'light.a', service: LightService.turnOff),
    );
    expect(c.isPending('light.a'), isTrue);

    await tester.pump(const Duration(seconds: 6));
    await tester.pump();

    // A failed re-read is render-only: it must never corrupt the cache.
    expect(c.isPending('light.a'), isFalse);
    final EntitySnapshot row = c.entities.single;
    expect(row.state, 'off');
    expect(row.lastUpdated, isNull);
  });

  testWidgets('a live state_changed cancels the confirmation timer',
      (WidgetTester tester) async {
    final DateTime authoritative = DateTime.utc(2026, 1, 1);
    hub.states = <EntitySnapshot>[
      EntitySnapshot(
        entityId: 'light.a',
        state: 'on',
        attributes: const <String, dynamic>{},
        lastUpdated: authoritative,
      ),
      EntitySnapshot(
        entityId: 'light.b',
        state: 'on',
        attributes: const <String, dynamic>{},
        lastUpdated: authoritative,
      ),
    ];
    final _FakeLiveState live = _FakeLiveState();
    final HubStatusController c = controller(live: live);
    addTearDown(c.dispose);
    await tester.pumpWidget(const SizedBox());
    await c.connect();

    await c.sendLightCommand(
      const LightCommand(entityId: 'light.a', service: LightService.turnOff),
    );
    await c.sendLightCommand(
      const LightCommand(entityId: 'light.b', service: LightService.turnOff),
    );
    expect(c.isPending('light.a'), isTrue);
    expect(c.isPending('light.b'), isTrue);

    // A's authoritative event arrives first: it confirms A and cancels A's timer.
    live.pushEvent(const EntityStateEvent(
      entityId: 'light.a',
      state: 'off',
      attributes: <String, dynamic>{'brightness': 5},
    ));
    await tester.pump();
    expect(c.isPending('light.a'), isFalse);

    // Past the deadline only B's timer fires; A's cancelled timer cannot
    // overwrite the event row with a re-read.
    await tester.pump(const Duration(seconds: 6));
    await tester.pump();

    final EntitySnapshot rowA = c.entities
        .firstWhere((EntitySnapshot e) => e.entityId == 'light.a');
    expect(rowA.state, 'off');
    expect(c.isPending('light.b'), isFalse);
    final EntitySnapshot rowB = c.entities
        .firstWhere((EntitySnapshot e) => e.entityId == 'light.b');
    expect(rowB.lastUpdated, isNotNull);
  });
}
