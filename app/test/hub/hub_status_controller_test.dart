import 'dart:async';

import 'package:daver_home/hub/hub_client.dart';
import 'package:daver_home/hub/hub_status_controller.dart';
import 'package:daver_home/hub/token_store.dart';
import 'package:daver_home/hub_status.dart';
import 'package:flutter_test/flutter_test.dart';

/// Scripted hub: each call returns its configured outcome.
class _FakeHubClient implements HubClient {
  Exception? probeError;
  Exception? statesError;
  List<EntitySnapshot> states = const <EntitySnapshot>[];

  /// When set, the probe waits on this before answering.
  Completer<void>? probeGate;

  @override
  Future<bool> probeHub() async {
    if (probeGate != null) {
      await probeGate!.future;
    }
    if (probeError != null) {
      throw probeError!;
    }
    return true;
  }

  @override
  Future<List<EntitySnapshot>> fetchStates() async {
    if (statesError != null) {
      throw statesError!;
    }
    return states;
  }

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

  HubStatusController controller() =>
      HubStatusController(client: hub, tokens: tokens);

  setUp(() {
    hub = _FakeHubClient();
    tokens = _FakeTokenStore('tok');
  });

  test('starts connecting before the first connect()', () {
    final HubStatusController c = controller();
    addTearDown(c.dispose);

    expect(c.status, HubStatus.connecting);
    expect(c.isConnected, isFalse);
  });

  test('is connecting while the probe is in flight', () async {
    hub.probeGate = Completer<void>();
    final HubStatusController c = controller();
    addTearDown(c.dispose);

    final Future<void> pending = c.connect();
    await Future<void>.delayed(Duration.zero);
    expect(c.status, HubStatus.connecting);

    hub.probeGate!.complete();
    await pending;
    expect(c.status, isNull);
  });

  test('no token: hubUnavailable, needsToken, and not connected', () async {
    tokens.token = null;
    final HubStatusController c = controller();
    addTearDown(c.dispose);

    await c.connect();

    expect(c.status, HubStatus.hubUnavailable);
    expect(c.needsToken, isTrue);
    expect(c.isConnected, isFalse);
  });

  test('an empty stored token counts as no token', () async {
    tokens.token = '';
    final HubStatusController c = controller();
    addTearDown(c.dispose);

    await c.connect();

    expect(c.needsToken, isTrue);
    expect(c.status, HubStatus.hubUnavailable);
  });

  test('probe and snapshot ok: connected and entities cached', () async {
    hub.states = const <EntitySnapshot>[
      EntitySnapshot(entityId: 'light.a', state: 'on', attributes: {}),
    ];
    final HubStatusController c = controller();
    addTearDown(c.dispose);

    await c.connect();

    expect(c.status, isNull);
    expect(c.isConnected, isTrue);
    expect(c.needsToken, isFalse);
    expect(c.entities.map((EntitySnapshot e) => e.entityId), <String>['light.a']);
  });

  test('a failed snapshot still counts as connected', () async {
    hub.statesError = const HubUnavailableException();
    final HubStatusController c = controller();
    addTearDown(c.dispose);

    await c.connect();

    expect(c.isConnected, isTrue);
    expect(c.entities, isEmpty);
  });

  test('HubUnavailableException maps to hubUnavailable', () async {
    hub.probeError = const HubUnavailableException();
    final HubStatusController c = controller();
    addTearDown(c.dispose);

    await c.connect();

    expect(c.status, HubStatus.hubUnavailable);
    expect(c.isConnected, isFalse);
  });

  test('TokenRejectedException re-asks for a token, not a crash loop', () async {
    hub.probeError = const TokenRejectedException();
    final HubStatusController c = controller();
    addTearDown(c.dispose);

    await c.connect();

    expect(c.status, HubStatus.hubUnavailable);
    expect(c.needsToken, isTrue);
    expect(c.isConnected, isFalse);
  });

  test('DeviceOfflineException maps to offline', () async {
    hub.probeError = const DeviceOfflineException();
    final HubStatusController c = controller();
    addTearDown(c.dispose);

    await c.connect();

    expect(c.status, HubStatus.offline);
  });

  test('saveToken trims, writes, and re-probes to connected', () async {
    tokens.token = null;
    final HubStatusController c = controller();
    addTearDown(c.dispose);
    await c.connect();
    expect(c.needsToken, isTrue);

    await c.saveToken('  fresh  ');

    expect(tokens.token, 'fresh');
    expect(c.isConnected, isTrue);
    expect(c.needsToken, isFalse);
  });

  test('saveToken ignores an empty token', () async {
    tokens.token = null;
    final HubStatusController c = controller();
    addTearDown(c.dispose);

    await c.saveToken('   ');

    expect(tokens.token, isNull);
    expect(c.isConnected, isFalse);
  });

  test('notifies listeners on status changes', () async {
    final HubStatusController c = controller();
    addTearDown(c.dispose);
    int notifications = 0;
    c.addListener(() => notifications++);

    await c.connect();

    expect(notifications, greaterThanOrEqualTo(2));
  });
}
