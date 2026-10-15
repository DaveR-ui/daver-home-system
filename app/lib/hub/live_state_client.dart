/// One `state_changed` event from the Home Assistant WebSocket, reduced to
/// the fields the render cache needs. HA stays the state authority (ADR-0005):
/// this is a render-cache update only, never a decision input.
class EntityStateEvent {
  const EntityStateEvent({
    required this.entityId,
    required this.state,
    required this.attributes,
    this.lastUpdated,
  });

  final String entityId;
  final String state;
  final Map<String, dynamic> attributes;

  /// HA's `new_state.last_updated` (UTC). Used ONLY to drop duplicate or
  /// out-of-order renders; null when HA omits it.
  final DateTime? lastUpdated;
}

/// The live connection's contribution to the app's reachability model.
/// The controller maps it onto the 3-value `HubStatus`: connecting and
/// reconnecting → `connecting`; offline → `offline`; tokenRejected →
/// hubUnavailable + needsToken; hubUnavailable → hubUnavailable; connected →
/// the banner hides.
enum LiveStatus {
  connecting,
  connected,
  reconnecting,
  hubUnavailable,
  offline,
  tokenRejected,
}

/// The app's port over Home Assistant's WebSocket surface. Fake-able in
/// tests; the production implementation is `WsLiveStateClient`.
abstract class LiveStateClient {
  /// Decoded `state_changed` events for the render cache.
  Stream<EntityStateEvent> get events;

  /// The live connection state; drives the reactive banner.
  Stream<LiveStatus> get status;

  /// The entities the render cache currently holds; re-read after a
  /// reconnect to close the disconnect gap.
  void setTrackedEntities(Iterable<String> entityIds);

  /// Connects, authenticates, subscribes, and keeps reconnecting.
  Future<void> start();

  /// Cancels reconnects and closes the socket.
  Future<void> stop();
}
