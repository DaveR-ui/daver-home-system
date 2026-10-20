import 'dart:convert';

import 'package:http/http.dart' as http;

import 'hub_client.dart';
import 'hub_rest_transport.dart';

/// Static fallback host for the hub, per the design doc. mDNS discovery
/// supersedes this in increment 3; a build may override it with
/// `--dart-define=HUB_BASE_URL=…` (a device/demo address).
const String defaultHubBaseUrl = String.fromEnvironment(
  'HUB_BASE_URL',
  defaultValue: 'http://homeassistant.local:8123',
);

/// The REST implementation of [HubClient] over `package:http`.
///
/// The [http.Client] and the token reader are injected so tests never touch
/// the network or the OS keystore. The wire work — the request build, the
/// per-request timeout, and the mapping of every failure onto the typed
/// exceptions — is delegated to a shared [HubRestTransport], so the same rule
/// serves reads and writes and cannot drift from [HttpLightCommandClient].
final class HttpHubClient implements HubClient {
  HttpHubClient({
    required this.client,
    required this.tokenReader,
    this.baseUrl = defaultHubBaseUrl,
  }) : _transport = HubRestTransport(
          client: client,
          tokenReader: tokenReader,
          baseUrl: baseUrl,
        );

  final http.Client client;

  /// Reads the long-lived token on every request, so a token saved after
  /// startup is picked up without rebuilding the client.
  final Future<String?> Function() tokenReader;

  final String baseUrl;

  final HubRestTransport _transport;

  @override
  Future<bool> probeHub() async {
    // Any 2xx counts; the body's "API running." message is not required.
    await _get('/api/');
    return true;
  }

  @override
  Future<List<EntitySnapshot>> fetchStates() async {
    final http.Response response = await _get('/api/states');
    final Object? decoded = _decodeJson(response.body);
    if (decoded is! List<Object?>) {
      throw const HubUnavailableException(
        'Home Assistant returned an unexpected states payload.',
      );
    }
    try {
      return <EntitySnapshot>[
        for (final Object? row in decoded)
          EntitySnapshot.fromJson(row! as Map<String, dynamic>),
      ];
    } on Object {
      throw const HubUnavailableException(
        'Home Assistant returned an unexpected states payload.',
      );
    }
  }

  @override
  Future<EntitySnapshot> fetchEntity(String entityId) async {
    final http.Response response = await _get('/api/states/$entityId');
    final Object? decoded = _decodeJson(response.body);
    if (decoded is! Map<String, dynamic>) {
      throw const HubUnavailableException(
        'Home Assistant returned an unexpected state payload.',
      );
    }
    try {
      return EntitySnapshot.fromJson(decoded);
    } on Object {
      throw const HubUnavailableException(
        'Home Assistant returned an unexpected state payload.',
      );
    }
  }

  /// Performs an authenticated GET through the shared transport, so no
  /// transport type escapes this class.
  Future<http.Response> _get(String path) {
    return _transport.send(
      'GET',
      path,
      headers: <String, String>{'Accept': 'application/json'},
    );
  }

  Object? _decodeJson(String body) {
    try {
      return jsonDecode(body);
    } on FormatException {
      throw const HubUnavailableException(
        'Home Assistant returned a body that is not JSON.',
      );
    }
  }
}
