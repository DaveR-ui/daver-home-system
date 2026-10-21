import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:daver_home/hub/hub_client.dart';
import 'package:daver_home/hub/http_hub_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

/// Captures every request and answers with a scripted response or error.
class _FakeHttpClient extends http.BaseClient {
  _FakeHttpClient(this._respond);

  final Future<http.StreamedResponse> Function(http.BaseRequest request)
  _respond;
  final List<http.BaseRequest> requests = <http.BaseRequest>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    requests.add(request);
    return _respond(request);
  }
}

/// Mirrors `package:http` 1.6.0's IOClient wrapper: a ClientException that
/// also implements SocketException and forwards the wrapped errno.
class _WrappedClientSocketException extends http.ClientException
    implements SocketException {
  _WrappedClientSocketException(super.message, {required this.osError});

  @override
  final OSError? osError;

  @override
  InternetAddress? get address => null;

  @override
  int? get port => null;
}

http.StreamedResponse _reply(int status, String body) {
  return http.StreamedResponse(Stream.value(utf8.encode(body)), status);
}

Future<String?> _token() async => 'tok';

HttpHubClient _client(
  _FakeHttpClient fake, {
  Future<String?> Function()? token,
}) {
  return HttpHubClient(
    client: fake,
    tokenReader: token ?? _token,
    baseUrlReader: () => 'http://hub.test:8123',
  );
}

void main() {
  group('probeHub', () {
    test(
      '200 with API running is true, GET /api/, bearer token sent',
      () async {
        final _FakeHttpClient fake = _FakeHttpClient(
          (_) async => _reply(200, '{"message":"API running."}'),
        );

        expect(await _client(fake).probeHub(), isTrue);

        final http.BaseRequest request = fake.requests.single;
        expect(request.method, 'GET');
        expect(request.url.toString(), 'http://hub.test:8123/api/');
        expect(request.headers['Authorization'], 'Bearer tok');
        expect(request.headers['Accept'], 'application/json');
      },
    );

    test('204 is a successful probe', () async {
      // Any 2xx is a success: HA's read answers 200, but a 204 acceptance must
      // not be reported as a failure — both clients share this one rule.
      final _FakeHttpClient fake = _FakeHttpClient(
        (_) async => _reply(204, ''),
      );

      expect(await _client(fake).probeHub(), isTrue);
    });

    for (final int status in <int>[401, 403]) {
      test(
        '$status means the token was rejected: TokenRejectedException',
        () async {
          final _FakeHttpClient fake = _FakeHttpClient(
            (_) async => _reply(status, '{"message":"nope"}'),
          );

          expect(
            _client(fake).probeHub(),
            throwsA(isA<TokenRejectedException>()),
          );
        },
      );
    }

    test('500 is HubUnavailableException', () async {
      final _FakeHttpClient fake = _FakeHttpClient(
        (_) async => _reply(500, ''),
      );

      expect(_client(fake).probeHub(), throwsA(isA<HubUnavailableException>()));
    });

    test(
      'a SocketException with no errno is an unresolvable/unknown hub, not offline',
      () async {
        final _FakeHttpClient fake = _FakeHttpClient(
          (_) => Future<http.StreamedResponse>.error(
            const SocketException('Failed host lookup'),
          ),
        );

        expect(
          _client(fake).probeHub(),
          throwsA(isA<HubUnavailableException>()),
        );
      },
    );

    group('socket errors follow the design-doc offline rule', () {
      Future<void> expectMapsTo(Object error, Matcher matcher) {
        final _FakeHttpClient fake = _FakeHttpClient(
          (_) => Future<http.StreamedResponse>.error(error),
        );
        return expectLater(_client(fake).probeHub(), throwsA(matcher));
      }

      test('wrapped ENETUNREACH (101) is DeviceOfflineException', () {
        return expectMapsTo(
          _WrappedClientSocketException(
            'Network is unreachable',
            osError: const OSError('Network is unreachable', 101),
          ),
          isA<DeviceOfflineException>(),
        );
      });

      test('wrapped ECONNREFUSED (111) is HubUnavailableException', () {
        return expectMapsTo(
          _WrappedClientSocketException(
            'Connection refused',
            osError: const OSError('Connection refused', 111),
          ),
          isA<HubUnavailableException>(),
        );
      });

      test('plain ECONNREFUSED (111) at send is HubUnavailableException', () {
        return expectMapsTo(
          const SocketException(
            'Connection refused',
            osError: OSError('refused', 111),
          ),
          isA<HubUnavailableException>(),
        );
      });

      test('plain ENETUNREACH (101) at send is DeviceOfflineException', () {
        return expectMapsTo(
          const SocketException(
            'Network is unreachable',
            osError: OSError('unreachable', 101),
          ),
          isA<DeviceOfflineException>(),
        );
      });
    });

    test('TimeoutException is HubUnavailableException', () async {
      final _FakeHttpClient fake = _FakeHttpClient(
        (_) => Future<http.StreamedResponse>.error(TimeoutException('t')),
      );

      expect(_client(fake).probeHub(), throwsA(isA<HubUnavailableException>()));
    });

    test(
      'a missing token fails before any request leaves the device',
      () async {
        final _FakeHttpClient fake = _FakeHttpClient(
          (_) async => _reply(200, '{}'),
        );

        expect(
          _client(fake, token: () async => null).probeHub(),
          throwsA(isA<HubUnavailableException>()),
        );
        expect(fake.requests, isEmpty);
      },
    );
  });

  group('the base URL reader seam', () {
    test('reads the current address once per request', () async {
      final _FakeHttpClient fake = _FakeHttpClient(
        (_) async => _reply(200, '{"message":"API running."}'),
      );
      String baseUrl = 'http://old.test:8123';
      int reads = 0;
      final HttpHubClient client = HttpHubClient(
        client: fake,
        tokenReader: _token,
        baseUrlReader: () {
          reads++;
          return baseUrl;
        },
      );

      await client.probeHub();

      // Exactly one read per request: resolving twice would let one request
      // straddle two hubs if the address moved mid-flight.
      expect(reads, 1);
      expect(fake.requests.single.url.toString(), 'http://old.test:8123/api/');

      baseUrl = 'http://new.test:8123';
      await client.probeHub();

      expect(reads, 2);
      expect(fake.requests.last.url.toString(), 'http://new.test:8123/api/');
    });
  });

  group('fetchStates', () {
    test('maps the snapshot rows, null attributes become empty', () async {
      final _FakeHttpClient fake = _FakeHttpClient(
        (_) async => _reply(
          200,
          jsonEncode(<Map<String, Object?>>[
            <String, Object?>{
              'entity_id': 'light.kitchen',
              'state': 'on',
              'attributes': <String, Object?>{'brightness': 180},
            },
            <String, Object?>{
              'entity_id': 'sensor.temp',
              'state': '21.5',
              'attributes': null,
            },
          ]),
        ),
      );

      final List<EntitySnapshot> states = await _client(fake).fetchStates();

      expect(fake.requests.single.url.path, '/api/states');
      expect(states, hasLength(2));
      expect(states[0].entityId, 'light.kitchen');
      expect(states[0].state, 'on');
      expect(states[0].attributes, <String, dynamic>{'brightness': 180});
      expect(states[1].entityId, 'sensor.temp');
      expect(states[1].state, '21.5');
      expect(states[1].attributes, isEmpty);
    });

    test('a non-list body is HubUnavailableException', () async {
      final _FakeHttpClient fake = _FakeHttpClient(
        (_) async => _reply(200, '{}'),
      );

      expect(
        _client(fake).fetchStates(),
        throwsA(isA<HubUnavailableException>()),
      );
    });

    test('a body that is not JSON is HubUnavailableException', () async {
      final _FakeHttpClient fake = _FakeHttpClient(
        (_) async => _reply(200, '<html>'),
      );

      expect(
        _client(fake).fetchStates(),
        throwsA(isA<HubUnavailableException>()),
      );
    });
  });

  group('fetchEntity', () {
    test('decodes one entity row and sends the bearer token', () async {
      final _FakeHttpClient fake = _FakeHttpClient(
        (_) async => _reply(
          200,
          jsonEncode(<String, Object?>{
            'entity_id': 'light.kitchen',
            'state': 'on',
            'attributes': <String, Object?>{'brightness': 180},
            'last_updated': '2026-10-14T10:00:00+00:00',
          }),
        ),
      );

      final EntitySnapshot snapshot = await _client(
        fake,
      ).fetchEntity('light.kitchen');

      final http.BaseRequest request = fake.requests.single;
      expect(request.method, 'GET');
      expect(request.url.path, '/api/states/light.kitchen');
      expect(request.headers['Authorization'], 'Bearer tok');
      expect(snapshot.entityId, 'light.kitchen');
      expect(snapshot.state, 'on');
      expect(snapshot.attributes, <String, dynamic>{'brightness': 180});
      expect(snapshot.lastUpdated, DateTime.utc(2026, 10, 14, 10));
    });

    test('a missing last_updated and null attributes are tolerated', () async {
      final _FakeHttpClient fake = _FakeHttpClient(
        (_) async => _reply(
          200,
          jsonEncode(<String, Object?>{
            'entity_id': 'sensor.temp',
            'state': '21.5',
            'attributes': null,
          }),
        ),
      );

      final EntitySnapshot snapshot = await _client(
        fake,
      ).fetchEntity('sensor.temp');

      expect(snapshot.attributes, isEmpty);
      expect(snapshot.lastUpdated, isNull);
    });

    test('401 is TokenRejectedException', () async {
      final _FakeHttpClient fake = _FakeHttpClient(
        (_) async => _reply(401, '{"message":"nope"}'),
      );

      expect(
        _client(fake).fetchEntity('light.a'),
        throwsA(isA<TokenRejectedException>()),
      );
    });

    test('a non-object body is HubUnavailableException', () async {
      final _FakeHttpClient fake = _FakeHttpClient(
        (_) async => _reply(200, '[]'),
      );

      expect(
        _client(fake).fetchEntity('light.a'),
        throwsA(isA<HubUnavailableException>()),
      );
    });
  });
}
