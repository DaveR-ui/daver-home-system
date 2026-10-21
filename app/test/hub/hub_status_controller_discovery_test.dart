import 'dart:async';

import 'package:daver_home/hub/hub_address.dart';
import 'package:daver_home/hub/hub_client.dart';
import 'package:daver_home/hub/hub_discovery.dart';
import 'package:daver_home/hub/hub_status_controller.dart';
import 'package:daver_home/hub/token_store.dart';
import 'package:daver_home/hub_status.dart';
import 'package:flutter_test/flutter_test.dart';

/// A scripted [HubDiscovery]: one configured result plus a late-answer stream
/// the test pushes on. No plugin, no platform channel, no search.
class _FakeHubDiscovery implements HubDiscovery {
  _FakeHubDiscovery(this.result);

  HubDiscoveryResult result;

  /// When set, [discover] waits on it, so the test controls the ordering.
  Completer<void>? gate;

  int discoverCalls = 0;

  /// True once [discover] has produced its result.
  bool resolved = false;

  final StreamController<HubDiscovered> _late =
      StreamController<HubDiscovered>.broadcast();

  @override
  Stream<HubDiscovered> get lateAnswers => _late.stream;

  @override
  Future<HubDiscoveryResult> discover({required Duration timeout}) async {
    discoverCalls++;
    final Completer<void>? gate = this.gate;
    if (gate != null) {
      await gate.future;
    }
    resolved = true;
    return result;
  }

  @override
  Future<void> stop() async {
    if (!_late.isClosed) {
      await _late.close();
    }
  }

  /// Delivers an advertisement that arrived after the search resolved.
  void answerLate(HubDiscovered hub) => _late.add(hub);

  void dispose() {
    if (!_late.isClosed) {
      _late.close();
    }
  }
}

/// A hub that records the address it was asked to probe.
///
/// It reads the SAME [HubAddressReader] the production clients get, so the test
/// observes the address the app would really use, not a value copied in.
class _RecordingHubClient implements HubClient {
  _RecordingHubClient(this.address, this.discovery);

  final HubAddress address;
  final _FakeHubDiscovery discovery;

  final List<String> probedBaseUrls = <String>[];

  /// Whether the discovery search had completed when each probe was called.
  final List<bool> resolutionCompletedBeforeProbe = <bool>[];

  /// Per-probe outcome, keyed by the 0-based probe index. Null means success.
  Exception? Function(int index)? probeError;

  /// When set, the probe at [gatedProbe] waits for it.
  Completer<void>? probeGate;
  int gatedProbe = 0;

  /// Per-probe gates, keyed by the 0-based probe index, for tests that hold
  /// more than one attempt open at the same time.
  final Map<int, Completer<void>> probeGates = <int, Completer<void>>{};

  @override
  Future<bool> probeHub() async {
    final int index = probedBaseUrls.length;
    probedBaseUrls.add(address.read());
    resolutionCompletedBeforeProbe.add(discovery.resolved);
    final Completer<void>? gate =
        probeGates[index] ?? (index == gatedProbe ? probeGate : null);
    if (gate != null) {
      await gate.future;
    }
    final Exception? error = probeError?.call(index);
    if (error != null) {
      throw error;
    }
    return true;
  }

  @override
  Future<List<EntitySnapshot>> fetchStates() async => const <EntitySnapshot>[];

  @override
  Future<EntitySnapshot> fetchEntity(String entityId) async =>
      throw const HubUnavailableException();
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

const HubDiscovered _hub = HubDiscovered(
  name: 'Home Assistant',
  host: '192.168.1.50',
  port: 8123,
  baseUrl: 'http://192.168.1.50:8123',
);

const HubDiscovered _otherHub = HubDiscovered(
  name: 'Home Assistant (other)',
  host: '192.168.1.60',
  port: 8123,
  baseUrl: 'http://192.168.1.60:8123',
);

const String _fallback = 'http://homeassistant.local:8123';

void main() {
  late _FakeHubDiscovery discovery;
  late _RecordingHubClient hub;
  late _FakeTokenStore tokens;
  late HubAddress address;

  HubStatusController controller({
    bool hasOverride = false,
    String overrideBaseUrl = '',
  }) {
    return HubStatusController(
      client: hub,
      tokens: tokens,
      resolver: HubAddressResolver(
        hasOverride: hasOverride,
        overrideBaseUrl: overrideBaseUrl,
        fallbackBaseUrl: _fallback,
        discovery: discovery,
      ),
      address: address,
    );
  }

  setUp(() {
    discovery = _FakeHubDiscovery(
      const HubDiscoveryNotFound(HubNotFoundReason.timeout),
    );
    address = HubAddress(_fallback);
    hub = _RecordingHubClient(address, discovery);
    tokens = _FakeTokenStore('tok');
    addTearDown(discovery.dispose);
  });

  test('a discovered hub is the address the probe uses', () async {
    discovery.result = const HubDiscoveryFound(_hub);
    final HubStatusController c = controller();
    addTearDown(c.dispose);

    await c.connect();

    expect(hub.probedBaseUrls, <String>['http://192.168.1.50:8123']);
    expect(address.baseUrl, 'http://192.168.1.50:8123');
    expect(discovery.discoverCalls, 1);
    expect(c.isConnected, isTrue);
  });

  test(
    'the static fallback still connects when no advertisement is seen',
    () async {
      discovery.result = const HubDiscoveryNotFound(
        HubNotFoundReason.noAdvertisement,
      );
      final HubStatusController c = controller();
      addTearDown(c.dispose);

      await c.connect();

      expect(hub.probedBaseUrls, <String>[_fallback]);
      expect(discovery.discoverCalls, 1);
      expect(c.isConnected, isTrue);
      expect(c.needsToken, isFalse);
    },
  );

  test('a blocked multicast search falls back and still connects', () async {
    discovery.result = const HubDiscoveryNotFound(
      HubNotFoundReason.pluginUnavailable,
    );
    final HubStatusController c = controller();
    addTearDown(c.dispose);

    await c.connect();

    expect(hub.probedBaseUrls, <String>[_fallback]);
    expect(c.isConnected, isTrue);
    expect(c.status, isNull);
  });

  test('an explicit override skips the search entirely', () async {
    discovery.result = const HubDiscoveryFound(_hub);
    final HubStatusController c = controller(
      hasOverride: true,
      overrideBaseUrl: '  http://10.0.2.2:8123/  ',
    );
    addTearDown(c.dispose);

    await c.connect();

    expect(discovery.discoverCalls, 0);
    expect(hub.probedBaseUrls, <String>['http://10.0.2.2:8123']);
    expect(address.baseUrl, 'http://10.0.2.2:8123');
    expect(c.isConnected, isTrue);
  });

  test('a reachable hub publishes exactly connecting then success', () async {
    discovery.result = const HubDiscoveryFound(_hub);
    final HubStatusController c = controller();
    addTearDown(c.dispose);
    final List<HubStatus?> statuses = <HubStatus?>[];
    c.addListener(() => statuses.add(c.status));

    await c.connect();

    expect(statuses, <HubStatus?>[HubStatus.connecting, null]);
  });

  test(
    'an unreachable hub publishes exactly connecting then hubUnavailable',
    () async {
      discovery.result = const HubDiscoveryFound(_hub);
      hub.probeError = (int index) => const HubUnavailableException();
      final HubStatusController c = controller();
      addTearDown(c.dispose);
      final List<HubStatus?> statuses = <HubStatus?>[];
      c.addListener(() => statuses.add(c.status));

      await c.connect();

      expect(statuses, <HubStatus?>[
        HubStatus.connecting,
        HubStatus.hubUnavailable,
      ]);
    },
  );

  test(
    'the probe runs only after the discovery search has completed',
    () async {
      discovery.result = const HubDiscoveryFound(_hub);
      discovery.gate = Completer<void>();
      final HubStatusController c = controller();
      addTearDown(c.dispose);

      final Future<void> pending = c.connect();
      await pumpEventQueue();

      expect(discovery.resolved, isFalse);
      expect(hub.probedBaseUrls, isEmpty);

      discovery.gate!.complete();
      await pending;

      expect(discovery.resolved, isTrue);
      expect(hub.resolutionCompletedBeforeProbe, <bool>[true]);
      expect(hub.probedBaseUrls, <String>['http://192.168.1.50:8123']);
    },
  );

  test('a superseded attempt cannot flip the status', () async {
    hub.probeGate = Completer<void>();
    final HubStatusController c = controller();
    addTearDown(c.dispose);
    final List<HubStatus?> statuses = <HubStatus?>[];
    c.addListener(() => statuses.add(c.status));

    final Future<void> first = c.connect();
    await pumpEventQueue();
    expect(hub.probedBaseUrls, hasLength(1));

    // The newest attempt probes again and succeeds while the first is still
    // gated: its outcome is the one that stands.
    await c.connect();
    expect(c.isConnected, isTrue);
    final List<HubStatus?> afterNewest = List<HubStatus?>.of(statuses);

    // The stale attempt now fails, in reverse order, and must write nothing.
    hub.probeError = (int index) => const HubUnavailableException();
    hub.probeGate!.complete();
    await first;

    expect(statuses, afterNewest);
    expect(c.status, isNull);
  });

  test(
    'a token re-entry reuses the resolved address instead of searching again',
    () async {
      discovery.result = const HubDiscoveryFound(_hub);
      final HubStatusController c = controller();
      addTearDown(c.dispose);
      await c.connect();
      expect(discovery.discoverCalls, 1);

      await c.saveToken('fresh');

      expect(discovery.discoverCalls, 1);
      expect(hub.probedBaseUrls, <String>[
        'http://192.168.1.50:8123',
        'http://192.168.1.50:8123',
      ]);
      expect(c.isConnected, isTrue);
    },
  );

  test(
    'a late answer updates the address and the next probe uses it',
    () async {
      discovery.result = const HubDiscoveryNotFound(HubNotFoundReason.timeout);
      // The fallback address is wrong, so the first probe fails; the discovered
      // one is right.
      hub.probeError = (int index) =>
          index == 0 ? const HubUnavailableException() : null;
      final HubStatusController c = controller();
      addTearDown(c.dispose);

      await c.connect();
      expect(hub.probedBaseUrls, <String>[_fallback]);
      expect(c.status, HubStatus.hubUnavailable);

      discovery.answerLate(_hub);
      await pumpEventQueue();

      expect(address.baseUrl, 'http://192.168.1.50:8123');
      expect(hub.probedBaseUrls, <String>[
        _fallback,
        'http://192.168.1.50:8123',
      ]);
      expect(c.isConnected, isTrue);
    },
  );

  test(
    'a late answer while connected does not flip the banner to connecting',
    () async {
      discovery.result = const HubDiscoveryFound(_hub);
      final HubStatusController c = controller();
      addTearDown(c.dispose);
      final List<HubStatus?> statuses = <HubStatus?>[];
      c.addListener(() => statuses.add(c.status));

      await c.connect();
      expect(c.isConnected, isTrue);
      final List<HubStatus?> afterConnected = List<HubStatus?>.of(statuses);

      discovery.answerLate(_otherHub);
      await pumpEventQueue();

      // The address that probed successfully stays pinned: moving the REST client
      // while the live socket stays on this hub would split the app across two
      // hubs, and a connected hub needs no second probe or status transition.
      expect(address.baseUrl, 'http://192.168.1.50:8123');
      expect(statuses, afterConnected);
      expect(c.isConnected, isTrue);
      expect(hub.probedBaseUrls, hasLength(1));
    },
  );

  test(
    'a late answer during a successful probe does not re-probe or move',
    () async {
      discovery.result = const HubDiscoveryFound(_hub);
      hub.probeGate = Completer<void>();
      final HubStatusController c = controller();
      addTearDown(c.dispose);
      final List<HubStatus?> statuses = <HubStatus?>[];
      c.addListener(() => statuses.add(c.status));

      final Future<void> pending = c.connect();
      await pumpEventQueue();
      expect(hub.probedBaseUrls, <String>['http://192.168.1.50:8123']);

      // The answer lands while the probe is gated: it is deferred, not applied.
      discovery.answerLate(_otherHub);
      await pumpEventQueue();
      expect(address.baseUrl, 'http://192.168.1.50:8123');
      expect(hub.probedBaseUrls, hasLength(1));

      hub.probeGate!.complete();
      await pending;
      await pumpEventQueue();

      // The attempt ended connected, so the deferred answer is discarded: exactly
      // one probe, the successful address stays pinned, and `connecting` never
      // reappears.
      expect(hub.probedBaseUrls, <String>['http://192.168.1.50:8123']);
      expect(address.baseUrl, 'http://192.168.1.50:8123');
      expect(statuses, <HubStatus?>[HubStatus.connecting, null]);
      expect(c.isConnected, isTrue);
    },
  );

  test('a deferred late answer retries once when the probe fails', () async {
    discovery.result = const HubDiscoveryNotFound(HubNotFoundReason.timeout);
    hub.probeError = (int index) =>
        index == 0 ? const HubUnavailableException() : null;
    hub.probeGate = Completer<void>();
    final HubStatusController c = controller();
    addTearDown(c.dispose);
    final List<HubStatus?> statuses = <HubStatus?>[];
    c.addListener(() => statuses.add(c.status));

    final Future<void> pending = c.connect();
    await pumpEventQueue();
    expect(hub.probedBaseUrls, <String>[_fallback]);

    discovery.answerLate(_hub);
    await pumpEventQueue();
    // Deferred while the attempt runs: the probe still uses the address it was
    // started with, and no concurrent attempt is made.
    expect(address.baseUrl, _fallback);
    expect(hub.probedBaseUrls, <String>[_fallback]);

    hub.probeGate!.complete();
    await pending;
    await pumpEventQueue();

    // The failed attempt adopts the deferred address and starts exactly ONE
    // new attempt, which probes the advertised hub and connects.
    expect(hub.probedBaseUrls, <String>[_fallback, 'http://192.168.1.50:8123']);
    expect(address.baseUrl, 'http://192.168.1.50:8123');
    expect(statuses, <HubStatus?>[
      HubStatus.connecting,
      HubStatus.hubUnavailable,
      HubStatus.connecting,
      null,
    ]);
    expect(c.isConnected, isTrue);
  });

  test('a superseded attempt does not clear the in-flight latch', () async {
    discovery.result = const HubDiscoveryFound(_hub);
    hub.probeGates[0] = Completer<void>();
    hub.probeGates[1] = Completer<void>();
    final HubStatusController c = controller();
    addTearDown(c.dispose);

    final Future<void> first = c.connect();
    await pumpEventQueue();
    expect(hub.probedBaseUrls, hasLength(1));

    final Future<void> second = c.connect();
    await pumpEventQueue();
    expect(hub.probedBaseUrls, hasLength(2));

    // The superseded attempt finishes while the newest one is still gated. It
    // must leave the latch alone, so a late answer cannot start a third,
    // concurrent attempt.
    hub.probeGates[0]!.complete();
    await first;
    await pumpEventQueue();
    expect(c.status, HubStatus.connecting);

    discovery.answerLate(_otherHub);
    await pumpEventQueue();
    expect(hub.probedBaseUrls, hasLength(2));
    expect(address.baseUrl, 'http://192.168.1.50:8123');

    // The newest attempt's outcome stands, and the deferred answer is discarded
    // because that attempt connected.
    hub.probeGates[1]!.complete();
    await second;
    await pumpEventQueue();

    expect(hub.probedBaseUrls, hasLength(2));
    expect(address.baseUrl, 'http://192.168.1.50:8123');
    expect(c.isConnected, isTrue);
  });

  test('a stale resolution never overwrites a promoted address', () async {
    discovery.result = const HubDiscoveryFound(_hub);
    discovery.gate = Completer<void>();
    final HubStatusController c = controller();
    addTearDown(c.dispose);

    final Future<void> pending = c.connect();
    await pumpEventQueue();
    expect(discovery.discoverCalls, 1);

    // The address moves while the search is still running.
    expect(address.update('http://192.168.1.70:8123'), isTrue);

    discovery.gate!.complete();
    await pending;

    // The resolution landed after the move, so it must not overwrite the
    // promoted address; the probe follows the promoted one.
    expect(address.baseUrl, 'http://192.168.1.70:8123');
    expect(hub.probedBaseUrls, <String>['http://192.168.1.70:8123']);
    expect(c.isConnected, isTrue);
  });

  test(
    'refreshAddress keeps an in-flight resolution instead of searching again',
    () async {
      discovery.result = const HubDiscoveryFound(_hub);
      discovery.gate = Completer<void>();
      final HubStatusController c = controller();
      addTearDown(c.dispose);

      final Future<void> first = c.connect();
      await pumpEventQueue();
      expect(discovery.discoverCalls, 1);
      expect(discovery.resolved, isFalse);
      // Not connected yet, so a refresh does act.
      expect(c.status, HubStatus.connecting);

      final Future<void> refreshed = c.refreshAddress();
      await pumpEventQueue();

      // The in-flight resolution IS the current search: a refresh must neither
      // start a second one nor discard the one already running.
      expect(discovery.discoverCalls, 1);
      expect(discovery.resolved, isFalse);

      discovery.gate!.complete();
      await first;
      await refreshed;

      expect(discovery.discoverCalls, 1);
      expect(hub.probedBaseUrls, <String>['http://192.168.1.50:8123']);
      expect(address.baseUrl, 'http://192.168.1.50:8123');
      expect(c.isConnected, isTrue);
    },
  );

  test('refreshAddress leaves a connected hub alone', () async {
    discovery.result = const HubDiscoveryFound(_hub);
    final HubStatusController c = controller();
    addTearDown(c.dispose);
    await c.connect();
    expect(c.isConnected, isTrue);
    expect(discovery.discoverCalls, 1);

    await c.refreshAddress();

    // A connected hub's address is pinned: no new search, no new probe.
    expect(discovery.discoverCalls, 1);
    expect(hub.probedBaseUrls, <String>['http://192.168.1.50:8123']);
    expect(c.isConnected, isTrue);
    expect(address.baseUrl, 'http://192.168.1.50:8123');
  });

  test(
    'refreshAddress re-searches once for a hub that is not connected',
    () async {
      hub.probeError = (int index) =>
          index == 0 ? const HubUnavailableException() : null;
      final HubStatusController c = controller();
      addTearDown(c.dispose);
      await c.connect();
      expect(c.status, HubStatus.hubUnavailable);
      expect(discovery.discoverCalls, 1);

      // The LAN is now the one where the hub advertises itself.
      discovery.result = const HubDiscoveryFound(_hub);
      await c.refreshAddress();

      // Exactly one new bounded search and one new probe, using the new address.
      expect(discovery.discoverCalls, 2);
      expect(hub.probedBaseUrls, <String>[
        _fallback,
        'http://192.168.1.50:8123',
      ]);
      expect(address.baseUrl, 'http://192.168.1.50:8123');
      expect(c.isConnected, isTrue);
    },
  );
}
