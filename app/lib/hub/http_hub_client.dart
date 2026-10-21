import 'dart:convert';

import 'package:http/http.dart' as http;

import 'hub_address.dart';
import 'hub_client.dart';
import 'hub_rest_transport.dart';

/// The compile-time default hub base URL, per the design doc.
///
/// This one constant is two things: the default address when nothing else says
/// otherwise, and the demo/device override (`--dart-define=HUB_BASE_URL=…`).
/// The static fallback the mDNS search falls back to when it finds no hub (a
/// network that blocks multicast) is the documented default (`defaultHubHost`),
/// which this constant carries when no override is supplied — so an override
/// that is present but empty can never leave the app without an address.
const String defaultHubBaseUrl = String.fromEnvironment(
  'HUB_BASE_URL',
  defaultValue: defaultHubHost,
);

/// True when the build supplied an explicit `--dart-define=HUB_BASE_URL=…`.
///
/// The constant above cannot tell "unset" from "set to the empty string", so
/// the override is detected with the companion `bool.hasEnvironment`. It is a
/// compile-time constant, so it is `false` under `flutter test` — which is why
/// the precedence rule lives in `HubAddressResolver` behind a `bool`
/// parameter, not behind this constant.
const bool hasHubBaseUrlOverride = bool.hasEnvironment('HUB_BASE_URL');

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
    HubAddressReader? baseUrlReader,
  })  : baseUrlReader = baseUrlReader ?? _defaultHubBaseUrlReader,
        _transport = HubRestTransport(
          client: client,
          tokenReader: tokenReader,
          baseUrlReader: baseUrlReader ?? _defaultHubBaseUrlReader,
        );

  /// Falls back to the compile-time default, so a caller that omits the reader
  /// behaves exactly as the fixed-address client did.
  static String _defaultHubBaseUrlReader() => defaultHubBaseUrl;

  final http.Client client;

  /// Reads the long-lived token on every request, so a token saved after
  /// startup is picked up without rebuilding the client.
  final Future<String?> Function() tokenReader;

  /// Reads the hub base URL at use time, shared with every other hub client so
  /// a late mDNS answer takes effect without rebuilding anything.
  final HubAddressReader baseUrlReader;

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
