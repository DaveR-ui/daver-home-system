import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'hub_client.dart';

/// Upper bound per request so a silent hub cannot leave the banner spinning or
/// a pending command unconfirmed.
const Duration hubRequestTimeout = Duration(seconds: 10);

/// The shared REST transport for both Home Assistant clients.
///
/// `HttpHubClient` reads and `HttpLightCommandClient` writes; everything except
/// the method, path, and body is identical — the bearer-token read, the request
/// build, the per-request timeout, and the mapping of every failure onto the
/// typed exceptions — so that ladder lives here once instead of twice. The
/// [http.Client] and the token reader stay injected, so every test remains
/// fake-based: nothing here touches the network or the OS keystore.
final class HubRestTransport {
  HubRestTransport({
    required this.client,
    required this.tokenReader,
    required this.baseUrl,
  });

  final http.Client client;

  /// Reads the long-lived token on every request, so a token saved after
  /// startup is picked up without rebuilding the client.
  final Future<String?> Function() tokenReader;

  final String baseUrl;

  /// Sends one authenticated request and returns its successful response.
  ///
  /// Throws only the typed exceptions: [TokenRejectedException] on 401/403,
  /// [DeviceOfflineException] for a no-route errno, [HubUnavailableException]
  /// for every other failure — never a raw transport type.
  Future<http.Response> send(
    String method,
    String path, {
    Map<String, String> headers = const <String, String>{},
    String? body,
  }) async {
    final String token = await _readToken();
    final http.Request request =
        http.Request(method, Uri.parse('$baseUrl$path'))
          ..headers.addAll(<String, String>{
            'Authorization': 'Bearer $token',
            ...headers,
          });
    if (body != null) {
      request.body = body;
    }

    try {
      final http.StreamedResponse streamed =
          await client.send(request).timeout(hubRequestTimeout);
      final http.Response response =
          await http.Response.fromStream(streamed).timeout(hubRequestTimeout);
      throwForHubStatus(response.statusCode);
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
  /// banner only says "Phone offline" for a no-route errno. A refused
  /// connection or a DNS failure means the network is up and the hub is not:
  /// `hubUnavailable`.
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
      // The keystore error text is not ours to show and must not carry a token.
      throw const HubUnavailableException('The token store could not be read.');
    }
    if (token == null || token.isEmpty) {
      throw const HubUnavailableException('No Home Assistant token is stored.');
    }
    return token;
  }
}
