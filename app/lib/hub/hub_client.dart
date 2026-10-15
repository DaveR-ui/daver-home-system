/// Raised when Home Assistant itself refused the request or answered with an
/// error: a non-2xx response (401/403 means the token was rejected), or a
/// request that failed after it left the device.
class HubUnavailableException implements Exception {
  const HubUnavailableException([this.message = 'Home Assistant is unavailable.']);

  final String message;

  @override
  String toString() => message;
}

/// Raised when Home Assistant rejects the stored token (HTTP 401/403): it was
/// revoked or minted for another user, so the owner must mint and re-enter one.
/// A rejected token is a re-auth state, never a crash loop.
class TokenRejectedException extends HubUnavailableException {
  const TokenRejectedException([
    super.message = 'Home Assistant rejected the stored token.',
  ]);
}

/// Raised when the request never left the device (no usable network), so the
/// hub cannot be considered reachable from here.
class DeviceOfflineException implements Exception {
  const DeviceOfflineException([this.message = 'This device has no network.']);

  final String message;

  @override
  String toString() => message;
}

/// Linux errnos meaning the device itself has no route: ENETDOWN (100),
/// ENETUNREACH (101), EHOSTUNREACH (113). A no-route errno is what separates the
/// `offline` status (the phone has no usable network) from `hubUnavailable`
/// (the network is up and the hub is not). Shared by both client implementations
/// so the rule stays in one place.
const Set<int> noDeviceRouteErrnos = <int>{100, 101, 113};

/// Throws the typed exception for an HTTP status that is not a success.
///
/// Both REST clients share this one rule so they can never drift apart again:
/// **any 2xx is a success** — Home Assistant answers `200` for reads and for
/// service calls, and a `204 No Content` is an equally valid acceptance, so
/// rejecting a non-200 success would turn a working hub into a false failure.
/// `401`/`403` mean the stored token was rejected; every other status is an
/// unavailable hub.
void throwForHubStatus(int statusCode) {
  if (statusCode >= 200 && statusCode < 300) {
    return;
  }
  if (statusCode == 401 || statusCode == 403) {
    throw const TokenRejectedException();
  }
  throw HubUnavailableException('Home Assistant answered HTTP $statusCode.');
}

/// One entity row of the `GET /api/states` snapshot, cached for rendering only.
class EntitySnapshot {
  const EntitySnapshot({
    required this.entityId,
    required this.state,
    required this.attributes,
    this.lastUpdated,
  });

  final String entityId;
  final String state;
  final Map<String, dynamic> attributes;

  /// HA's `last_updated` (UTC). Used ONLY to order render-cache updates, so a
  /// duplicate or out-of-order event cannot overwrite a newer render. Null when
  /// HA omits it.
  final DateTime? lastUpdated;

  factory EntitySnapshot.fromJson(Map<String, dynamic> json) => EntitySnapshot(
        entityId: json['entity_id'] as String,
        state: json['state'] as String,
        attributes:
            (json['attributes'] as Map?)?.cast<String, dynamic>() ?? const {},
        lastUpdated: _parseTimestamp(json['last_updated']),
      );

  static DateTime? _parseTimestamp(Object? value) {
    if (value is! String) {
      return null;
    }
    return DateTime.tryParse(value)?.toUtc();
  }
}

/// The app's port over Home Assistant's REST surface. Fake-able in tests.
abstract class HubClient {
  /// `GET /api/`. Returns true when the API answers 200; throws otherwise.
  Future<bool> probeHub();

  /// `GET /api/states`. The full entity snapshot.
  Future<List<EntitySnapshot>> fetchStates();

  /// `GET /api/states/<entity_id>` — one entity row, used to close the gap
  /// after a WebSocket reconnect.
  Future<EntitySnapshot> fetchEntity(String entityId);
}
