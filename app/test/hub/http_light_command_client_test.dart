import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:daver_home/hub/hub_client.dart';
import 'package:daver_home/hub/http_light_command_client.dart';
import 'package:daver_home/hub/light_command.dart';
import 'package:daver_home/hub/light_command_client.dart';
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

/// A command client that records what it was asked to send, for the shared
/// style other suites reuse.
class _FakeCommandClient implements LightCommandClient {
  final List<LightCommand> sent = <LightCommand>[];

  @override
  Future<void> sendLightCommand(LightCommand command) async {
    sent.add(command);
  }
}

http.StreamedResponse _reply(int status, [String body = '']) {
  return http.StreamedResponse(Stream.value(utf8.encode(body)), status);
}

Future<String?> _token() async => 'tok';

HttpLightCommandClient _client(
  _FakeHttpClient fake, {
  Future<String?> Function()? token,
}) {
  return HttpLightCommandClient(
    client: fake,
    tokenReader: token ?? _token,
    baseUrl: 'http://hub.test:8123',
  );
}

http.Request _request(_FakeHttpClient fake) =>
    fake.requests.single as http.Request;

Map<String, dynamic> _body(http.Request request) =>
    jsonDecode(request.body) as Map<String, dynamic>;

void main() {
  group('service segment routing', () {
    const Map<LightService, String> segments = <LightService, String>{
      LightService.turnOn: 'turn_on',
      LightService.turnOff: 'turn_off',
      LightService.toggle: 'toggle',
    };

    for (final MapEntry<LightService, String> entry in segments.entries) {
      test('${entry.key.name} posts to /api/services/light/${entry.value}',
          () async {
        final _FakeHttpClient fake =
            _FakeHttpClient((_) async => _reply(200, '[]'));

        await _client(fake).sendLightCommand(
          LightCommand(entityId: 'light.kitchen_ceiling', service: entry.key),
        );

        final http.Request request = _request(fake);
        expect(request.method, 'POST');
        expect(
          request.url.toString(),
          'http://hub.test:8123/api/services/light/${entry.value}',
        );
        expect(request.headers['Content-Type'], 'application/json');
      });
    }
  });

  test('204 is an accepted command', () async {
    // A 204 No Content acceptance is a success, not a false failure: the
    // command landed on the hub and there is simply no body to read.
    final _FakeHttpClient fake = _FakeHttpClient((_) async => _reply(204));

    await _client(fake).sendLightCommand(
      const LightCommand(entityId: 'light.a', service: LightService.turnOn),
    );
  });

  test('the bearer token header is sent on every call', () async {
    final _FakeHttpClient fake =
        _FakeHttpClient((_) async => _reply(200, '[]'));

    await _client(fake).sendLightCommand(
      const LightCommand(entityId: 'light.a', service: LightService.turnOn),
    );
    await _client(fake).sendLightCommand(
      const LightCommand(entityId: 'light.a', service: LightService.turnOff),
    );

    expect(fake.requests, hasLength(2));
    for (final http.BaseRequest request in fake.requests) {
      expect(request.headers['Authorization'], 'Bearer tok');
    }
  });

  test('the body carries entity_id, and brightness only when set', () async {
    final _FakeHttpClient fake =
        _FakeHttpClient((_) async => _reply(200, '[]'));

    await _client(fake).sendLightCommand(
      const LightCommand(
        entityId: 'light.kitchen_ceiling',
        service: LightService.turnOn,
        brightness: 180,
      ),
    );

    final Map<String, dynamic> body = _body(_request(fake));
    expect(body['entity_id'], 'light.kitchen_ceiling');
    expect(body['brightness'], 180);
    expect(body.containsKey('rgb_color'), isFalse);
  });

  test('the body carries rgb_color only when set', () async {
    final _FakeHttpClient fake =
        _FakeHttpClient((_) async => _reply(200, '[]'));

    await _client(fake).sendLightCommand(
      const LightCommand(
        entityId: 'light.kitchen_ceiling',
        service: LightService.turnOn,
        rgbColor: <int>[255, 0, 0],
      ),
    );

    final Map<String, dynamic> body = _body(_request(fake));
    expect(body['entity_id'], 'light.kitchen_ceiling');
    expect(body['rgb_color'], <int>[255, 0, 0]);
    expect(body.containsKey('brightness'), isFalse);
  });

  test('a plain command body has only entity_id', () async {
    final _FakeHttpClient fake =
        _FakeHttpClient((_) async => _reply(200, '[]'));

    await _client(fake).sendLightCommand(
      const LightCommand(entityId: 'light.a', service: LightService.turnOff),
    );

    final Map<String, dynamic> body = _body(_request(fake));
    expect(body, <String, dynamic>{'entity_id': 'light.a'});
  });

  test('a missing token fails before any request leaves the device', () async {
    final _FakeHttpClient fake =
        _FakeHttpClient((_) async => _reply(200, '[]'));

    expect(
      _client(fake, token: () async => null).sendLightCommand(
        const LightCommand(entityId: 'light.a', service: LightService.turnOn),
      ),
      throwsA(isA<HubUnavailableException>()),
    );
    expect(fake.requests, isEmpty);
  });

  test('403 is TokenRejectedException', () async {
    final _FakeHttpClient fake =
        _FakeHttpClient((_) async => _reply(403, '{"message":"nope"}'));

    expect(
      _client(fake).sendLightCommand(
        const LightCommand(entityId: 'light.a', service: LightService.turnOn),
      ),
      throwsA(isA<TokenRejectedException>()),
    );
  });

  test('500 is HubUnavailableException', () async {
    final _FakeHttpClient fake = _FakeHttpClient((_) async => _reply(500));

    expect(
      _client(fake).sendLightCommand(
        const LightCommand(entityId: 'light.a', service: LightService.turnOn),
      ),
      throwsA(isA<HubUnavailableException>()),
    );
  });

  test('wrapped ENETUNREACH (101) is DeviceOfflineException', () async {
    final _FakeHttpClient fake = _FakeHttpClient(
      (_) => Future<http.StreamedResponse>.error(
        _WrappedClientSocketException(
          'Network is unreachable',
          osError: const OSError('Network is unreachable', 101),
        ),
      ),
    );

    expect(
      _client(fake).sendLightCommand(
        const LightCommand(entityId: 'light.a', service: LightService.turnOn),
      ),
      throwsA(isA<DeviceOfflineException>()),
    );
  });

  test('wrapped ECONNREFUSED (111) is HubUnavailableException', () async {
    final _FakeHttpClient fake = _FakeHttpClient(
      (_) => Future<http.StreamedResponse>.error(
        _WrappedClientSocketException(
          'Connection refused',
          osError: const OSError('Connection refused', 111),
        ),
      ),
    );

    expect(
      _client(fake).sendLightCommand(
        const LightCommand(entityId: 'light.a', service: LightService.turnOn),
      ),
      throwsA(isA<HubUnavailableException>()),
    );
  });

  test('TimeoutException is HubUnavailableException', () async {
    final _FakeHttpClient fake = _FakeHttpClient(
      (_) => Future<http.StreamedResponse>.error(TimeoutException('t')),
    );

    expect(
      _client(fake).sendLightCommand(
        const LightCommand(entityId: 'light.a', service: LightService.turnOn),
      ),
      throwsA(isA<HubUnavailableException>()),
    );
  });

  test('_FakeCommandClient records the command it is handed', () async {
    final _FakeCommandClient command = _FakeCommandClient();

    await command.sendLightCommand(
      const LightCommand(entityId: 'light.a', service: LightService.toggle),
    );

    expect(command.sent.single.service, LightService.toggle);
  });
}
