import 'dart:async';
import 'dart:io';

import 'package:daver_home/hub/hub_discovery.dart';
import 'package:daver_home/hub/hub_discovery_nsd.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nsd/nsd.dart' as nsd;

/// One fake platform search: tests push advertisements or end the stream.
class _FakeNsdSearch implements NsdSearch {
  final StreamController<HubDiscovered> _controller =
      StreamController<HubDiscovered>.broadcast();

  int stopCalls = 0;

  @override
  Stream<HubDiscovered> get services => _controller.stream;

  void emit(HubDiscovered hub) {
    if (!_controller.isClosed) {
      _controller.add(hub);
    }
  }

  void end() {
    if (!_controller.isClosed) {
      _controller.close();
    }
  }

  void fail(Object error) {
    if (!_controller.isClosed) {
      _controller.addError(error);
    }
  }

  @override
  Future<void> stop() async {
    stopCalls++;
    if (!_controller.isClosed) {
      await _controller.close();
    }
  }
}

/// A fake platform runner: never reaches `package:nsd`, never needs a channel.
class _FakeNsdRunner implements NsdRunner {
  _FakeNsdRunner({this.searchError});

  /// When set, `search` throws it, modelling a missing plugin or permission.
  final Object? searchError;

  final List<String> serviceTypes = <String>[];
  final List<_FakeNsdSearch> searches = <_FakeNsdSearch>[];

  @override
  Future<NsdSearch> search(String serviceType) async {
    serviceTypes.add(serviceType);
    final Object? error = searchError;
    if (error != null) {
      throw error;
    }
    final _FakeNsdSearch search = _FakeNsdSearch();
    searches.add(search);
    return search;
  }
}

/// A runner that never acknowledges the start, modelling the Android NSD
/// failure mode where `startDiscovery` never returns.
class _HangingNsdRunner implements NsdRunner {
  int searchCalls = 0;

  final Completer<NsdSearch> _never = Completer<NsdSearch>();

  @override
  Future<NsdSearch> search(String serviceType) {
    searchCalls++;
    return _never.future;
  }
}

/// A runner whose platform start answers only when the test says so, so two
/// `discover` calls can be in flight at the same time.
class _DeferredNsdRunner implements NsdRunner {
  final Completer<NsdSearch> _start = Completer<NsdSearch>();

  int searchCalls = 0;

  @override
  Future<NsdSearch> search(String serviceType) {
    searchCalls++;
    return _start.future;
  }

  void answer(NsdSearch search) => _start.complete(search);
}

/// A runner that exercises the REAL adapter over a hand-built
/// [nsd.Discovery]. `nsd.Discovery` is a plain in-memory list, so no platform
/// channel is touched; the stop call is injected to avoid `stopDiscovery`.
class _ReplayingNsdRunner implements NsdRunner {
  _ReplayingNsdRunner(this.discovery);

  final nsd.Discovery discovery;
  int searchCalls = 0;

  @override
  Future<NsdSearch> search(String serviceType) async {
    searchCalls++;
    return PackageNsdSearch(discovery, stopDiscovery: (_) async {});
  }
}

const nsd.Service _nsdService = nsd.Service(
  name: 'Home Assistant',
  type: homeAssistantServiceType,
  host: '192.168.1.50',
  port: 8123,
);

const HubDiscovered _hub = HubDiscovered(
  name: 'Home Assistant',
  host: '192.168.1.50',
  port: 8123,
  baseUrl: 'http://192.168.1.50:8123',
);

const Duration _deadline = Duration(milliseconds: 10);

HubNotFoundReason _reasonOf(HubDiscoveryResult result) {
  expect(result, isA<HubDiscoveryNotFound>());
  return (result as HubDiscoveryNotFound).reason;
}

void main() {
  group('NsdHubDiscovery', () {
    test('a found advertisement resolves with its base url', () async {
      final _FakeNsdRunner runner = _FakeNsdRunner();
      final NsdHubDiscovery discovery = NsdHubDiscovery(runner: runner);

      final Future<HubDiscoveryResult> pending = discovery.discover(
        timeout: const Duration(seconds: 5),
      );
      await pumpEventQueue();
      runner.searches.single.emit(_hub);

      final HubDiscoveryResult result = await pending;

      expect(result, isA<HubDiscoveryFound>());
      expect(
        (result as HubDiscoveryFound).hub.baseUrl,
        'http://192.168.1.50:8123',
      );
      expect(result.hub.host, '192.168.1.50');
      expect(result.hub.port, 8123);

      await discovery.stop();
    });

    test('the default service type is the Home Assistant one', () async {
      final _FakeNsdRunner runner = _FakeNsdRunner();
      final NsdHubDiscovery discovery = NsdHubDiscovery(runner: runner);

      await discovery.discover(timeout: _deadline);

      expect(runner.serviceTypes, <String>['_home-assistant._tcp']);
      expect(discovery.serviceType, '_home-assistant._tcp');

      await discovery.stop();
    });

    test('the service type is injectable', () async {
      final _FakeNsdRunner runner = _FakeNsdRunner();
      final NsdHubDiscovery discovery = NsdHubDiscovery(
        runner: runner,
        serviceType: '_custom._tcp',
      );

      await discovery.discover(timeout: _deadline);

      expect(runner.serviceTypes, <String>['_custom._tcp']);

      await discovery.stop();
    });

    test('an advertisement that never arrives is a timeout', () async {
      final _FakeNsdRunner runner = _FakeNsdRunner();
      final NsdHubDiscovery discovery = NsdHubDiscovery(runner: runner);

      final HubDiscoveryResult result = await discovery.discover(
        timeout: _deadline,
      );

      expect(_reasonOf(result), HubNotFoundReason.timeout);

      await discovery.stop();
    });

    test('a search that ends with nothing is noAdvertisement', () async {
      final _FakeNsdRunner runner = _FakeNsdRunner();
      final NsdHubDiscovery discovery = NsdHubDiscovery(runner: runner);

      final Future<HubDiscoveryResult> pending = discovery.discover(
        timeout: const Duration(seconds: 5),
      );
      await pumpEventQueue();
      runner.searches.single.end();

      final HubDiscoveryResult result = await pending;

      expect(_reasonOf(result), HubNotFoundReason.noAdvertisement);

      await discovery.stop();
    });

    test(
      'a runner that throws is pluginUnavailable, never an exception',
      () async {
        final _FakeNsdRunner runner = _FakeNsdRunner(
          searchError: StateError('MissingPluginException'),
        );
        final NsdHubDiscovery discovery = NsdHubDiscovery(runner: runner);

        final HubDiscoveryResult result = await discovery.discover(
          timeout: const Duration(seconds: 5),
        );

        expect(_reasonOf(result), HubNotFoundReason.pluginUnavailable);

        await discovery.stop();
      },
    );

    test(
      'a platform stream error is pluginUnavailable, never an exception',
      () async {
        final _FakeNsdRunner runner = _FakeNsdRunner();
        final NsdHubDiscovery discovery = NsdHubDiscovery(runner: runner);

        final Future<HubDiscoveryResult> pending = discovery.discover(
          timeout: const Duration(seconds: 5),
        );
        await pumpEventQueue();
        runner.searches.single.fail(StateError('multicast blocked'));

        final HubDiscoveryResult result = await pending;

        expect(_reasonOf(result), HubNotFoundReason.pluginUnavailable);

        await discovery.stop();
      },
    );

    test(
      'an advertisement after the deadline arrives on lateAnswers',
      () async {
        final _FakeNsdRunner runner = _FakeNsdRunner();
        final NsdHubDiscovery discovery = NsdHubDiscovery(runner: runner);

        final HubDiscoveryResult first = await discovery.discover(
          timeout: _deadline,
        );
        expect(_reasonOf(first), HubNotFoundReason.timeout);

        final Future<HubDiscovered> late = discovery.lateAnswers.first;
        runner.searches.single.emit(_hub);

        expect((await late).baseUrl, 'http://192.168.1.50:8123');

        await discovery.stop();
      },
    );

    test('stop is idempotent and releases the platform search', () async {
      final _FakeNsdRunner runner = _FakeNsdRunner();
      final NsdHubDiscovery discovery = NsdHubDiscovery(runner: runner);

      final Future<HubDiscoveryResult> pending = discovery.discover(
        timeout: const Duration(seconds: 5),
      );
      await pumpEventQueue();

      await discovery.stop();
      await discovery.stop();

      expect(runner.searches.single.stopCalls, 1);
      // A waiter is released rather than left hanging once the search is torn
      // down; the port still answers with a typed result.
      expect(_reasonOf(await pending), HubNotFoundReason.pluginUnavailable);
    });

    test('lateAnswers does not throw before a search starts', () async {
      final NsdHubDiscovery discovery = NsdHubDiscovery(
        runner: _FakeNsdRunner(),
      );

      // Subscribing is safe even though nothing has been searched yet; the
      // broadcast stream simply stays silent until a search produces an answer.
      final StreamSubscription<HubDiscovered> subscription = discovery
          .lateAnswers
          .listen((_) {});

      await subscription.cancel();
      await discovery.stop();
    });

    test(
      'a platform start that never answers is a timeout, not a hang',
      () async {
        final _HangingNsdRunner runner = _HangingNsdRunner();
        final NsdHubDiscovery discovery = NsdHubDiscovery(runner: runner);

        final HubDiscoveryResult result = await discovery
            .discover(timeout: const Duration(milliseconds: 50))
            // Fails the test instead of hanging if the deadline is not applied.
            .timeout(const Duration(seconds: 2));

        expect(_reasonOf(result), HubNotFoundReason.timeout);
        expect(runner.searchCalls, 1);

        await discovery.stop();
      },
    );

    test(
      'stop is not terminal: a later discover starts a fresh search',
      () async {
        final _FakeNsdRunner runner = _FakeNsdRunner();
        final NsdHubDiscovery discovery = NsdHubDiscovery(runner: runner);

        final Future<HubDiscoveryResult> first = discovery.discover(
          timeout: const Duration(seconds: 5),
        );
        await pumpEventQueue();

        await discovery.stop();
        expect(_reasonOf(await first), HubNotFoundReason.pluginUnavailable);

        // Calling it again is harmless: the first call already released the
        // search, so nothing is stopped twice.
        await discovery.stop();
        expect(runner.searches.single.stopCalls, 1);

        final Future<HubDiscoveryResult> second = discovery.discover(
          timeout: const Duration(seconds: 5),
        );
        await pumpEventQueue();

        expect(runner.searches, hasLength(2));
        runner.searches.last.emit(_hub);

        final HubDiscoveryResult result = await second;
        expect(result, isA<HubDiscoveryFound>());
        expect((result as HubDiscoveryFound).hub.baseUrl, _hub.baseUrl);

        await discovery.stop();
        expect(runner.searches.last.stopCalls, 1);
      },
    );

    test('lateAnswers keeps working across a stop/start cycle', () async {
      final _FakeNsdRunner runner = _FakeNsdRunner();
      final NsdHubDiscovery discovery = NsdHubDiscovery(runner: runner);
      final List<HubDiscovered> late = <HubDiscovered>[];
      final StreamSubscription<HubDiscovered> subscription = discovery
          .lateAnswers
          .listen(late.add);

      expect(
        _reasonOf(await discovery.discover(timeout: _deadline)),
        HubNotFoundReason.timeout,
      );
      await discovery.stop();

      expect(
        _reasonOf(await discovery.discover(timeout: _deadline)),
        HubNotFoundReason.timeout,
      );
      expect(runner.searches, hasLength(2));

      runner.searches.last.emit(_hub);
      await pumpEventQueue();

      expect(late, hasLength(1));
      expect(late.single.baseUrl, _hub.baseUrl);

      await subscription.cancel();
      await discovery.stop();
    });

    test(
      'two discover calls that share a platform start both get the first answer',
      () async {
        final _DeferredNsdRunner runner = _DeferredNsdRunner();
        final NsdHubDiscovery discovery = NsdHubDiscovery(runner: runner);
        final List<HubDiscovered> late = <HubDiscovered>[];
        final StreamSubscription<HubDiscovered> subscription = discovery
            .lateAnswers
            .listen(late.add);

        final Future<HubDiscoveryResult> first = discovery.discover(
          timeout: const Duration(seconds: 5),
        );
        final Future<HubDiscoveryResult> second = discovery.discover(
          timeout: const Duration(seconds: 5),
        );
        await pumpEventQueue();

        // Both calls wait on the same in-flight platform start.
        expect(runner.searchCalls, 1);

        final _FakeNsdSearch search = _FakeNsdSearch();
        runner.answer(search);
        await pumpEventQueue();
        search.emit(_hub);

        final HubDiscoveryResult firstResult = await first;
        final HubDiscoveryResult secondResult = await second;

        // Neither call starved until its deadline: the FIRST advertisement
        // answered both of them.
        expect(firstResult, isA<HubDiscoveryFound>());
        expect(secondResult, isA<HubDiscoveryFound>());
        expect((firstResult as HubDiscoveryFound).hub.baseUrl, _hub.baseUrl);
        expect((secondResult as HubDiscoveryFound).hub.baseUrl, _hub.baseUrl);

        // The advertisement is delivered ONCE: it must not also show up as a
        // late answer on the second, leaked subscription.
        await pumpEventQueue();
        expect(late, isEmpty);

        // No second platform search was started for the second call.
        expect(runner.searchCalls, 1);

        await subscription.cancel();
        await discovery.stop();
      },
    );
  });

  group('PackageNsdSearch buffering', () {
    test(
      'delivers a service collected before the subscriber attaches',
      () async {
        final nsd.Discovery platform = nsd.Discovery('test-discovery');
        // Collected during startDiscovery, before the adapter exists.
        platform.add(_nsdService);

        final PackageNsdSearch search = PackageNsdSearch(
          platform,
          stopDiscovery: (_) async {},
        );

        final List<HubDiscovered> seen = <HubDiscovered>[];
        final StreamSubscription<HubDiscovered> subscription = search.services
            .listen(seen.add);
        await pumpEventQueue();

        expect(seen, hasLength(1));
        expect(seen.single.baseUrl, 'http://192.168.1.50:8123');

        await subscription.cancel();
        await search.stop();
      },
    );

    test(
      'an advertisement is delivered exactly once, even on re-announcement',
      () async {
        final nsd.Discovery platform = nsd.Discovery('test-discovery');
        platform.add(_nsdService);

        final PackageNsdSearch search = PackageNsdSearch(
          platform,
          stopDiscovery: (_) async {},
        );

        final List<HubDiscovered> seen = <HubDiscovered>[];
        final StreamSubscription<HubDiscovered> subscription = search.services
            .listen(seen.add);
        await pumpEventQueue();
        expect(seen, hasLength(1));

        // A live copy of the same address: a different name makes `nsd` treat it
        // as another service, so only the adapter's dedupe can suppress it.
        platform.add(
          const nsd.Service(
            name: 'Home Assistant (renamed)',
            type: homeAssistantServiceType,
            host: '192.168.1.50',
            port: 8123,
          ),
        );
        await pumpEventQueue();

        expect(seen, hasLength(1));

        await subscription.cancel();
        await search.stop();
      },
    );

    test('ignores a lost notification', () async {
      final nsd.Discovery platform = nsd.Discovery('test-discovery');
      const nsd.Service service = nsd.Service(
        name: 'Home Assistant',
        type: homeAssistantServiceType,
        host: '192.168.1.50',
        port: 8123,
      );
      platform.add(service);

      final PackageNsdSearch search = PackageNsdSearch(
        platform,
        stopDiscovery: (_) async {},
      );
      final List<HubDiscovered> seen = <HubDiscovered>[];
      final StreamSubscription<HubDiscovered> subscription = search.services
          .listen(seen.add);
      await pumpEventQueue();
      expect(seen, hasLength(1));

      platform.remove(service);
      await pumpEventQueue();

      expect(seen, hasLength(1));

      await subscription.cancel();
      await search.stop();
    });

    test(
      'a service collected during the start is found by NsdHubDiscovery',
      () async {
        final nsd.Discovery platform = nsd.Discovery('test-discovery');
        platform.add(_nsdService);
        final _ReplayingNsdRunner runner = _ReplayingNsdRunner(platform);
        final NsdHubDiscovery discovery = NsdHubDiscovery(runner: runner);

        final HubDiscoveryResult result = await discovery.discover(
          timeout: const Duration(seconds: 1),
        );

        expect(result, isA<HubDiscoveryFound>());
        expect((result as HubDiscoveryFound).hub.baseUrl, _hub.baseUrl);
        expect(runner.searchCalls, 1);

        await discovery.stop();
      },
    );
  });

  group('hubDiscoveredFromNsdService', () {
    test('uses the advertised host and port', () {
      final HubDiscovered? hub = hubDiscoveredFromNsdService(_nsdService);

      expect(hub, isNotNull);
      expect(hub!.name, 'Home Assistant');
      expect(hub.host, '192.168.1.50');
      expect(hub.port, 8123);
      expect(hub.baseUrl, 'http://192.168.1.50:8123');
    });

    test('falls back to the first IPv4 address when the host is empty', () {
      final HubDiscovered? hub = hubDiscoveredFromNsdService(
        nsd.Service(
          name: 'Home Assistant',
          type: homeAssistantServiceType,
          host: '',
          addresses: <InternetAddress>[
            InternetAddress('fe80::1'),
            InternetAddress('192.168.1.50'),
            InternetAddress('10.0.0.2'),
          ],
        ),
      );

      expect(hub, isNotNull);
      expect(hub!.host, '192.168.1.50');
      expect(hub.baseUrl, 'http://192.168.1.50:8123');
    });

    test('defaults the port to 8123 when the platform omits it', () {
      final HubDiscovered? hub = hubDiscoveredFromNsdService(
        const nsd.Service(
          name: 'Home Assistant',
          type: homeAssistantServiceType,
          host: '192.168.1.50',
        ),
      );

      expect(hub, isNotNull);
      expect(hub!.port, homeAssistantHubPort);
      expect(hub.baseUrl, 'http://192.168.1.50:8123');
    });

    test('brackets an IPv6 literal in the base URL', () {
      final HubDiscovered? hub = hubDiscoveredFromNsdService(
        const nsd.Service(
          name: 'Home Assistant',
          type: homeAssistantServiceType,
          host: 'fe80::1',
          port: 8123,
        ),
      );

      expect(hub, isNotNull);
      expect(hub!.host, 'fe80::1');
      expect(hub.baseUrl, 'http://[fe80::1]:8123');
    });

    test('returns null with neither a host nor an IPv4 address', () {
      expect(
        hubDiscoveredFromNsdService(
          const nsd.Service(
            name: 'Home Assistant',
            type: homeAssistantServiceType,
            host: '',
          ),
        ),
        isNull,
      );
      expect(
        hubDiscoveredFromNsdService(
          nsd.Service(
            name: 'Home Assistant',
            type: homeAssistantServiceType,
            host: '   ',
            addresses: <InternetAddress>[InternetAddress('fe80::1')],
          ),
        ),
        isNull,
      );
    });

    test('falls back to the host as the name', () {
      final HubDiscovered? hub = hubDiscoveredFromNsdService(
        const nsd.Service(
          type: homeAssistantServiceType,
          host: '192.168.1.50',
          port: 8123,
        ),
      );

      expect(hub, isNotNull);
      expect(hub!.name, '192.168.1.50');
    });
  });
}
