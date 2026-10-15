import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'hub_client.dart';

/// Static fallback host for the hub, per the design doc. mDNS discovery
/// supersedes this in increment 3.
const String defaultHubBaseUrl = 'http://homeassistant.local:8123';

/// Upper bound per request so a silent hub cannot leave the banner spinning.
const Duration _requestTimeout = Duration(seconds: 10);

/// The REST implementation of [HubClient] over `package:http`.
///
/// The [http.Client] and the token reader are injected so tests never touch
/// the network or the OS keystore.
final class HttpHubClient implements HubClient {
  HttpHubClient({
    required this.client,
    required this.tokenReader,
    this.baseUrl = defaultHubBaseUrl,
  });

  final http.Client client;

  /// Reads the long-lived token on every request, so a token saved after
  /// startup is picked up without rebuilding the client.
  final Future<String?> Function() tokenReader;

  final String baseUrl;

  @override
  Future<bool> probeHub() async {
    // Any 200 counts; the body's "API running." message is not required.
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

  /// Performs an authenticated GET and maps every failure onto the two typed
  /// exceptions, so no transport type escapes this class.
  Future<http.Response> _get(String path) async {
    final String token = await _readToken();
    final http.Request request = http.Request(
      'GET',
      Uri.parse('$baseUrl$path'),
    )..headers.addAll(<String, String>{
        'Authorization': 'Bearer $token',
        'Accept': 'application/json',
      });

    try {
      final http.StreamedResponse streamed =
          await client.send(request).timeout(_requestTimeout);
      final http.Response response =
          await http.Response.fromStream(streamed).timeout(_requestTimeout);
      _throwForStatus(response.statusCode);
      return response;
    } on HubUnavailableException {
      rethrow;
    } on SocketException catch (e) {
      // Checked before ClientException: IOClient throws a ClientException that
      // also implements SocketException, so its osError carries the same errno.
      throw _mapSocketException(e);
    } on TimeoutException {
      throw const HubUnavailableException('Home Assistant did not respond.');
    } on http.ClientException {
      throw const HubUnavailableException('Home Assistant is unreachable.');
    } on HttpException {
      throw const HubUnavailableException('Home Assistant is unreachable.');
    }
  }

  /// Design-doc rule: `offline` means the device has no usable network, so the
  /// banner only says "Phone offline" for a no-route errno. A refused connection
  /// or a DNS failure means the network is up and the hub is not: `hubUnavailable`.
  static Exception _mapSocketException(SocketException e) {
    final int? errno = e.osError?.errorCode;
    if (errno != null && noDeviceRouteErrnos.contains(errno)) {
      return const DeviceOfflineException();
    }
    return const HubUnavailableException('Home Assistant is unreachable.');
  }

  Future<String> _readToken() async {
    final String? token;
    try {
      token = await tokenReader();
    } on Object {
      // The keystore error text is not ours to show, and must not carry a token.
      throw const HubUnavailableException('The token store could not be read.');
    }
    if (token == null || token.isEmpty) {
      throw const HubUnavailableException('No Home Assistant token is stored.');
    }
    return token;
  }

  void _throwForStatus(int statusCode) {
    if (statusCode == 200) {
      return;
    }
    if (statusCode == 401 || statusCode == 403) {
      throw const TokenRejectedException();
    }
    throw HubUnavailableException('Home Assistant answered HTTP $statusCode.');
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
