import 'dart:async';

import 'package:daver_home/hub/hub_client.dart';
import 'package:daver_home/hub/hub_status_controller.dart';
import 'package:daver_home/hub/live_state_client.dart';
import 'package:daver_home/hub/token_store.dart';
import 'package:daver_home/hub_status.dart';
import 'package:flutter_test/flutter_test.dart';

/// A live-state source the test drives directly through its broadcast streams.
class _FakeLiveState implements LiveStateClient {
  final StreamController<EntityStateEvent> _events =
      StreamController<EntityStateEvent>.broadcast();
  final StreamController<LiveStatus> _status =
      StreamController<LiveStatus>.broadcast();

  final List<String> tracked = <String>[];
  bool started = false;
  bool stopped = false;

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
  Future<void> stop() async => stopped = true;

  void pushEvent(EntityStateEvent event) => _events.add(event);

  void pushStatus(LiveStatus status) => _status.add(status);
}

/// A hub whose probe always passes and whose snapshot/fetchEntity are scripted.
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

void main() {
  late _FakeHubClient hub;
  late _FakeTokenStore tokens;
  late _FakeLiveState live;

  HubStatusController controller() => HubStatusController(
        client: hub,
        tokens: tokens,
        liveState: live,
      );

  setUp(() {
    hub = _FakeHubClient();
    tokens = _FakeTokenStore('tok');
    live = _FakeLiveState();
  });

  test('a live event adds and updates the render cache, sorted by entity id',
      () async {
    hub.states = <EntitySnapshot>[
      const EntitySnapshot(
        entityId: 'sensor.b',
        state: '21',
        attributes: <String, dynamic>{},
      ),
      const EntitySnapshot(
        entityId: 'light.a',
        state: 'off',
        attributes: <String, dynamic>{},
      ),
    ];
    final HubStatusController c = controller();
    addTearDown(c.dispose);
    int notifications = 0;
    c.addListener(() => notifications++);

    await c.connect();
    expect(live.started, isTrue);
    final int afterConnect = notifications;

    live.pushEvent(const EntityStateEvent(
      entityId: 'light.c',
      state: 'on',
      attributes: <String, dynamic>{'brightness': 180},
    ));
    await pumpEventQueue();

    expect(notifications, greaterThan(afterConnect));
    expect(
      c.entities.map((EntitySnapshot e) => e.entityId),
      <String>['light.a', 'light.c', 'sensor.b'],
    );
    expect(
      c.entities.firstWhere((EntitySnapshot e) => e.entityId == 'light.c').state,
      'on',
    );

    // A later event updates the same row in place.
    live.pushEvent(const EntityStateEvent(
      entityId: 'light.c',
      state: 'off',
      attributes: <String, dynamic>{},
    ));
    await pumpEventQueue();

    expect(
      c.entities.firstWhere((EntitySnapshot e) => e.entityId == 'light.c').state,
      'off',
    );
  });

  test('duplicate and older events are ignored; newer and undated apply',
      () async {
    final HubStatusController c = controller();
    addTearDown(c.dispose);
    await c.connect();

    final DateTime first = DateTime.utc(2026, 1, 1);
    final DateTime second = DateTime.utc(2026, 1, 2);

    live.pushEvent(EntityStateEvent(
      entityId: 'light.a',
      state: 'on',
      attributes: const <String, dynamic>{},
      lastUpdated: second,
    ));
    await pumpEventQueue();
    expect(c.entities.single.state, 'on');

    // Same timestamp: a duplicate, so the render is unchanged.
    live.pushEvent(EntityStateEvent(
      entityId: 'light.a',
      state: 'off',
      attributes: const <String, dynamic>{},
      lastUpdated: second,
    ));
    await pumpEventQueue();
    expect(c.entities.single.state, 'on');

    // Older: out of order, so it is dropped.
    live.pushEvent(EntityStateEvent(
      entityId: 'light.a',
      state: 'dim',
      attributes: const <String, dynamic>{},
      lastUpdated: first,
    ));
    await pumpEventQueue();
    expect(c.entities.single.state, 'on');

    // Newer: applied.
    live.pushEvent(EntityStateEvent(
      entityId: 'light.a',
      state: 'bright',
      attributes: const <String, dynamic>{},
      lastUpdated: DateTime.utc(2026, 1, 3),
    ));
    await pumpEventQueue();
    expect(c.entities.single.state, 'bright');

    // Undated: applied (HA omitted last_updated).
    live.pushEvent(const EntityStateEvent(
      entityId: 'light.a',
      state: 'final',
      attributes: <String, dynamic>{},
    ));
    await pumpEventQueue();
    expect(c.entities.single.state, 'final');
  });

  test('live status maps onto HubStatus, with the probe result taking precedence',
      () async {
    final HubStatusController c = controller();
    addTearDown(c.dispose);
    await c.connect();
    expect(c.isConnected, isTrue);

    live.pushStatus(LiveStatus.connecting);
    await pumpEventQueue();
    expect(c.status, HubStatus.connecting);

    live.pushStatus(LiveStatus.reconnecting);
    await pumpEventQueue();
    expect(c.status, HubStatus.connecting);

    live.pushStatus(LiveStatus.connected);
    await pumpEventQueue();
    expect(c.status, isNull);
    expect(c.isConnected, isTrue);

    live.pushStatus(LiveStatus.tokenRejected);
    await pumpEventQueue();
    expect(c.status, HubStatus.hubUnavailable);
    expect(c.needsToken, isTrue);

    live.pushStatus(LiveStatus.offline);
    await pumpEventQueue();
    expect(c.status, HubStatus.offline);
    expect(c.needsToken, isTrue);

    live.pushStatus(LiveStatus.hubUnavailable);
    await pumpEventQueue();
    expect(c.status, HubStatus.hubUnavailable);
  });

  test('the probe failure outranks the live status', () async {
    hub.states = const <EntitySnapshot>[];
    final HubStatusController c = controller();
    addTearDown(c.dispose);
    await c.connect();
    expect(c.isConnected, isTrue);

    // A live reconnecting status becomes connecting...
    live.pushStatus(LiveStatus.reconnecting);
    await pumpEventQueue();
    expect(c.status, HubStatus.connecting);

    // ...but once the probe fails, the probe result wins.
    hub.probeError = const DeviceOfflineException();
    await c.connect();
    expect(c.status, HubStatus.offline);
  });

  test('the tracked set follows the render cache after a change', () async {
    hub.states = <EntitySnapshot>[
      const EntitySnapshot(
        entityId: 'light.a',
        state: 'on',
        attributes: <String, dynamic>{},
      ),
    ];
    final HubStatusController c = controller();
    addTearDown(c.dispose);
    await c.connect();

    expect(live.tracked, containsAll(<String>['light.a']));

    live.pushEvent(const EntityStateEvent(
      entityId: 'light.b',
      state: 'on',
      attributes: <String, dynamic>{},
    ));
    await pumpEventQueue();

    expect(live.tracked, containsAll(<String>['light.a', 'light.b']));
  });

  test('a live connected does not clear the re-auth requirement', () async {
    final HubStatusController c = controller();
    addTearDown(c.dispose);
    await c.connect();

    live.pushStatus(LiveStatus.tokenRejected);
    await pumpEventQueue();
    expect(c.needsToken, isTrue);

    // Only the probe clears needsToken; a live connected must not hide the
    // re-auth surface while the probe still says the hub is unavailable.
    live.pushStatus(LiveStatus.connected);
    await pumpEventQueue();
    expect(c.needsToken, isTrue);
    expect(c.status, isNull);
  });

  test('dispose stops the live client and later emissions notify nobody',
      () async {
    final HubStatusController c = controller();
    int notifications = 0;
    c.addListener(() => notifications++);
    await c.connect();

    c.dispose();
    await pumpEventQueue();

    expect(live.stopped, isTrue);

    final int before = notifications;
    live.pushEvent(const EntityStateEvent(
      entityId: 'light.a',
      state: 'on',
      attributes: <String, dynamic>{},
    ));
    live.pushStatus(LiveStatus.offline);
    await pumpEventQueue();

    expect(notifications, before);
  });

  test('without a live client the controller is the REST-only increment',
      () async {
    hub.states = <EntitySnapshot>[
      const EntitySnapshot(
        entityId: 'light.a',
        state: 'on',
        attributes: <String, dynamic>{},
      ),
    ];
    final HubStatusController c = HubStatusController(client: hub, tokens: tokens);
    addTearDown(c.dispose);

    await c.connect();

    expect(c.isConnected, isTrue);
    expect(c.needsToken, isFalse);
    expect(
      c.entities.map((EntitySnapshot e) => e.entityId),
      <String>['light.a'],
    );
  });
}
