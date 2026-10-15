import 'dart:convert';

import 'package:http/http.dart' as http;

import 'hub_rest_transport.dart';
import 'http_hub_client.dart';
import 'light_command.dart';
import 'light_command_client.dart';

/// The REST implementation of [LightCommandClient] over `package:http`.
///
/// Mirrors [HttpHubClient]'s guarded style: the [http.Client] and the token
/// reader are injected so tests never touch the network or the OS keystore, and
/// every failure maps onto the shared typed exceptions. The only call it makes
/// is `POST /api/services/light/<segment>` — Home Assistant is the authority
/// (ADR-0005), so there is no other write path. The wire work delegates to a
/// shared [HubRestTransport], so reads and writes share one transport rule.
final class HttpLightCommandClient implements LightCommandClient {
  HttpLightCommandClient({
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
  Future<void> sendLightCommand(LightCommand command) async {
    await _transport.send(
      'POST',
      '/api/services/light/${command.serviceSegment}',
      headers: <String, String>{'Content-Type': 'application/json'},
      body: _encodeBody(command),
    );
  }

  /// The JSON body: `entity_id` always, `brightness`/`rgb_color` only when set.
  String _encodeBody(LightCommand command) {
    final Map<String, dynamic> body = <String, dynamic>{
      'entity_id': command.entityId,
    };
    final int? brightness = command.brightness;
    if (brightness != null) {
      body['brightness'] = brightness;
    }
    final List<int>? rgbColor = command.rgbColor;
    if (rgbColor != null) {
      body['rgb_color'] = rgbColor;
    }
    return jsonEncode(body);
  }
}
