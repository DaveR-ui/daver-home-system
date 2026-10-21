import 'package:daver_home/hub/hub_address.dart';
import 'package:daver_home/hub/hub_discovery.dart';
import 'package:flutter_test/flutter_test.dart';

/// A scripted [HubDiscovery] that records how often the resolver searched.
class _FakeHubDiscovery implements HubDiscovery {
  _FakeHubDiscovery(this.result);

  final HubDiscoveryResult result;
  int discoverCalls = 0;
  int stopCalls = 0;
  Duration? lastTimeout;

  @override
  Stream<HubDiscovered> get lateAnswers => const Stream<HubDiscovered>.empty();

  @override
  Future<HubDiscoveryResult> discover({required Duration timeout}) async {
    discoverCalls++;
    lastTimeout = timeout;
    return result;
  }

  @override
  Future<void> stop() async {
    stopCalls++;
  }
}

/// A broken port: the resolver must still produce a resolution, never throw.
class _ThrowingHubDiscovery implements HubDiscovery {
  @override
  Stream<HubDiscovered> get lateAnswers => const Stream<HubDiscovered>.empty();

  @override
  Future<HubDiscoveryResult> discover({required Duration timeout}) async {
    throw StateError('the search could not run');
  }

  @override
  Future<void> stop() async {}
}

const HubDiscovered _hub = HubDiscovered(
  name: 'Home Assistant',
  host: '192.168.1.50',
  port: 8123,
  baseUrl: 'http://192.168.1.50:8123',
);

const String _fallback = 'http://homeassistant.local:8123';

void main() {
  group('HubAddress', () {
    test('starts at the normalized base url', () {
      expect(
        HubAddress('  http://hub.test:8123/  ').baseUrl,
        'http://hub.test:8123',
      );
    });

    test('update adopts a real change and reports it', () {
      final HubAddress address = HubAddress('http://hub.test:8123');

      expect(address.update('http://192.168.1.50:8123'), isTrue);
      expect(address.baseUrl, 'http://192.168.1.50:8123');
    });

    test('update ignores an equal address, even with a trailing slash', () {
      final HubAddress address = HubAddress('http://hub.test:8123');

      expect(address.update('http://hub.test:8123/'), isFalse);
      expect(address.baseUrl, 'http://hub.test:8123');
    });

    test('update ignores an unusable value and keeps the current address', () {
      final HubAddress address = HubAddress('http://hub.test:8123');

      expect(address.update('not a url'), isFalse);
      expect(address.update('ftp://hub.test:8123'), isFalse);
      expect(address.update('   '), isFalse);
      expect(address.baseUrl, 'http://hub.test:8123');
    });

    test('a previously taken read tear-off observes the later change', () {
      final HubAddress address = HubAddress('http://hub.test:8123');
      final HubAddressReader read = address.read;

      expect(read(), 'http://hub.test:8123');

      address.update('http://192.168.1.50:8123');

      expect(read(), 'http://192.168.1.50:8123');
      expect(address.baseUrl, 'http://192.168.1.50:8123');
    });

    test('generation starts at zero and grows on an accepted change', () {
      final HubAddress address = HubAddress('http://hub.test:8123');

      expect(address.generation, 0);

      expect(address.update('http://192.168.1.50:8123'), isTrue);
      expect(address.generation, 1);

      expect(address.update('http://homeassistant.local:8123'), isTrue);
      expect(address.generation, 2);
    });

    test('generation does not grow on an unchanged or unusable value', () {
      final HubAddress address = HubAddress('http://hub.test:8123');

      // The same value, even in its trailing-slash form.
      expect(address.update('http://hub.test:8123'), isFalse);
      expect(address.update('http://hub.test:8123/'), isFalse);
      expect(address.update('not a url'), isFalse);
      expect(address.update('ftp://hub.test:8123'), isFalse);

      expect(address.generation, 0);
      expect(address.baseUrl, 'http://hub.test:8123');
    });
  });

  group('normalizeHubBaseUrl', () {
    test('strips a trailing slash', () {
      expect(
        normalizeHubBaseUrl('http://192.168.1.50:8123/'),
        'http://192.168.1.50:8123',
      );
    });

    test('trims surrounding whitespace', () {
      expect(
        normalizeHubBaseUrl('  http://192.168.1.50:8123  '),
        'http://192.168.1.50:8123',
      );
    });

    test('accepts https', () {
      expect(
        normalizeHubBaseUrl('https://hub.test:8123/'),
        'https://hub.test:8123',
      );
    });

    test('rejects a non-http scheme', () {
      expect(normalizeHubBaseUrl('ftp://hub.test:8123'), isEmpty);
      expect(normalizeHubBaseUrl('ws://hub.test:8123'), isEmpty);
    });

    test('rejects an empty host', () {
      expect(normalizeHubBaseUrl('http://'), isEmpty);
      expect(normalizeHubBaseUrl('http:///api'), isEmpty);
    });

    test('rejects a value that is not a url', () {
      expect(normalizeHubBaseUrl('not a url'), isEmpty);
      expect(normalizeHubBaseUrl('   '), isEmpty);
    });

    test('returns an already-normalized value unchanged', () {
      const String normalized = 'http://192.168.1.50:8123';

      expect(normalizeHubBaseUrl(normalized), normalized);
    });

    test('canonicalizes a trailing slash', () {
      expect(
        normalizeHubBaseUrl('http://host:8123/'),
        normalizeHubBaseUrl('http://host:8123'),
      );
      expect(normalizeHubBaseUrl('http://host:8123/'), 'http://host:8123');
    });

    test('rejects credentials', () {
      expect(normalizeHubBaseUrl('http://user:pw@host:8123'), isEmpty);
      expect(normalizeHubBaseUrl('http://user@host:8123'), isEmpty);
    });

    test('rejects a path', () {
      expect(normalizeHubBaseUrl('http://host:8123/api'), isEmpty);
      expect(normalizeHubBaseUrl('http://host:8123/api/'), isEmpty);
    });

    test('rejects a query', () {
      expect(normalizeHubBaseUrl('http://host:8123/?x=1'), isEmpty);
      expect(normalizeHubBaseUrl('http://host:8123?x=1'), isEmpty);
    });

    test('rejects a fragment', () {
      expect(normalizeHubBaseUrl('http://host:8123/#frag'), isEmpty);
      expect(normalizeHubBaseUrl('http://host:8123#frag'), isEmpty);
    });
  });

  group('usableHubBaseUrl', () {
    test('returns a usable candidate in its normalized form', () {
      expect(usableHubBaseUrl('http://hub.test:8123'), 'http://hub.test:8123');
      expect(
        usableHubBaseUrl('  http://hub.test:8123/  '),
        'http://hub.test:8123',
      );
    });

    test('returns the documented default for an empty candidate', () {
      expect(defaultHubHost, 'http://homeassistant.local:8123');
      expect(usableHubBaseUrl(''), defaultHubHost);
      expect(usableHubBaseUrl('   '), defaultHubHost);
    });

    test('returns the documented default for a malformed candidate', () {
      expect(usableHubBaseUrl('not a url'), defaultHubHost);
      expect(usableHubBaseUrl('ftp://hub.test:8123'), defaultHubHost);
    });
  });

  group('HubAddressResolver', () {
    HubAddressResolver resolver(
      _FakeHubDiscovery discovery, {
      bool hasOverride = false,
      String overrideBaseUrl = '',
    }) {
      return HubAddressResolver(
        hasOverride: hasOverride,
        overrideBaseUrl: overrideBaseUrl,
        fallbackBaseUrl: _fallback,
        discovery: discovery,
      );
    }

    test('an explicit override wins and the search is never called', () async {
      final _FakeHubDiscovery discovery = _FakeHubDiscovery(
        const HubDiscoveryFound(_hub),
      );

      final HubResolution resolution = await resolver(
        discovery,
        hasOverride: true,
        overrideBaseUrl: '  http://10.0.2.2:8123/  ',
      ).resolve();

      expect(resolution.baseUrl, 'http://10.0.2.2:8123');
      expect(resolution.source, HubAddressSource.explicitOverride);
      expect(resolution.miss, isNull);
      expect(discovery.discoverCalls, 0);
    });

    test('a found advertisement wins without an override', () async {
      final _FakeHubDiscovery discovery = _FakeHubDiscovery(
        const HubDiscoveryFound(_hub),
      );

      final HubResolution resolution = await resolver(discovery).resolve();

      expect(resolution.baseUrl, 'http://192.168.1.50:8123');
      expect(resolution.source, HubAddressSource.mdns);
      expect(resolution.miss, isNull);
      expect(discovery.discoverCalls, 1);
    });

    test(
      'a miss falls back to the static host and carries the observation',
      () async {
        final _FakeHubDiscovery discovery = _FakeHubDiscovery(
          const HubDiscoveryNotFound(HubNotFoundReason.timeout),
        );

        final HubResolution resolution = await resolver(discovery).resolve();

        expect(resolution.baseUrl, _fallback);
        expect(resolution.source, HubAddressSource.staticFallback);
        expect(resolution.miss, isNotNull);
        expect(resolution.miss!.reason, HubNotFoundReason.timeout);
      },
    );

    for (final HubNotFoundReason reason in HubNotFoundReason.values) {
      test('carries a ${reason.name} miss on the fallback', () async {
        final _FakeHubDiscovery discovery = _FakeHubDiscovery(
          HubDiscoveryNotFound(reason),
        );

        final HubResolution resolution = await resolver(discovery).resolve();

        expect(resolution.source, HubAddressSource.staticFallback);
        expect(resolution.miss!.reason, reason);
      });
    }

    test(
      'an override that is present but empty falls through to the search',
      () async {
        final _FakeHubDiscovery discovery = _FakeHubDiscovery(
          const HubDiscoveryFound(_hub),
        );

        final HubResolution resolution = await resolver(
          discovery,
          hasOverride: true,
          overrideBaseUrl: '   ',
        ).resolve();

        expect(resolution.baseUrl, 'http://192.168.1.50:8123');
        expect(resolution.source, HubAddressSource.mdns);
        expect(discovery.discoverCalls, 1);
      },
    );

    test(
      'an empty override that misses resolves to the documented default',
      () async {
        final _FakeHubDiscovery discovery = _FakeHubDiscovery(
          const HubDiscoveryNotFound(HubNotFoundReason.timeout),
        );

        final HubResolution resolution = await resolver(
          discovery,
          hasOverride: true,
          overrideBaseUrl: '',
        ).resolve();

        // The empty define is not an override: the search ran, and its miss
        // still leaves the app with the documented default host.
        expect(discovery.discoverCalls, 1);
        expect(resolution.baseUrl, defaultHubHost);
        expect(resolution.baseUrl, isNotEmpty);
        expect(resolution.source, HubAddressSource.staticFallback);
        expect(resolution.miss!.reason, HubNotFoundReason.timeout);
      },
    );

    test(
      'a malformed override that misses resolves to the documented default',
      () async {
        final _FakeHubDiscovery discovery = _FakeHubDiscovery(
          const HubDiscoveryNotFound(HubNotFoundReason.pluginUnavailable),
        );

        final HubResolution resolution = await resolver(
          discovery,
          hasOverride: true,
          overrideBaseUrl: 'not a url',
        ).resolve();

        expect(discovery.discoverCalls, 1);
        expect(resolution.baseUrl, defaultHubHost);
        expect(resolution.source, HubAddressSource.staticFallback);
        expect(resolution.miss!.reason, HubNotFoundReason.pluginUnavailable);
      },
    );

    test(
      'an empty fallback still resolves to the documented default',
      () async {
        final _FakeHubDiscovery discovery = _FakeHubDiscovery(
          const HubDiscoveryNotFound(HubNotFoundReason.noAdvertisement),
        );

        final HubResolution resolution = await HubAddressResolver(
          hasOverride: false,
          overrideBaseUrl: '',
          fallbackBaseUrl: '',
          discovery: discovery,
        ).resolve();

        expect(resolution.baseUrl, defaultHubHost);
        expect(resolution.source, HubAddressSource.staticFallback);
        expect(resolution.miss!.reason, HubNotFoundReason.noAdvertisement);
      },
    );

    test('a misbehaving search still resolves to the fallback', () async {
      final HubAddressResolver resolver = HubAddressResolver(
        hasOverride: false,
        overrideBaseUrl: '',
        fallbackBaseUrl: _fallback,
        discovery: _ThrowingHubDiscovery(),
      );

      final HubResolution resolution = await resolver.resolve();

      expect(resolution.baseUrl, _fallback);
      expect(resolution.source, HubAddressSource.staticFallback);
      expect(resolution.miss!.reason, HubNotFoundReason.pluginUnavailable);
    });

    test('the search runs for the configured timeout', () async {
      final _FakeHubDiscovery discovery = _FakeHubDiscovery(
        const HubDiscoveryNotFound(HubNotFoundReason.timeout),
      );

      await HubAddressResolver(
        hasOverride: false,
        overrideBaseUrl: '',
        fallbackBaseUrl: _fallback,
        discovery: discovery,
        timeout: const Duration(seconds: 7),
      ).resolve();

      expect(discovery.lastTimeout, const Duration(seconds: 7));
    });
  });
}
