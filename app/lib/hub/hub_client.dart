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

/// One entity row of the `GET /api/states` snapshot, cached for rendering only.
class EntitySnapshot {
  const EntitySnapshot({
    required this.entityId,
    required this.state,
    required this.attributes,
  });

  final String entityId;
  final String state;
  final Map<String, dynamic> attributes;

  factory EntitySnapshot.fromJson(Map<String, dynamic> json) => EntitySnapshot(
        entityId: json['entity_id'] as String,
        state: json['state'] as String,
        attributes:
            (json['attributes'] as Map?)?.cast<String, dynamic>() ?? const {},
      );
}

/// The app's port over Home Assistant's REST surface. Fake-able in tests.
abstract class HubClient {
  /// `GET /api/`. Returns true when the API answers 200; throws otherwise.
  Future<bool> probeHub();

  /// `GET /api/states`. The full entity snapshot.
  Future<List<EntitySnapshot>> fetchStates();
}
