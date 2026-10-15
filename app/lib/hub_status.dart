/// The app's only model of hub reachability.
///
/// This enum says whether the app can reach Home Assistant, never what the
/// hub's state is: Home Assistant remains the single state authority
/// (ADR-0005), and the app holds a cache for rendering only. The future hub
/// client drives these values from the `GET /api/` probe plus the WebSocket
/// connection state.
enum HubStatus {
  /// The app is establishing or re-establishing contact with the hub.
  connecting,

  /// The hub could not be reached, so no state can be confirmed or trusted.
  hubUnavailable,

  /// The phone has no usable network, so the hub is out of reach entirely.
  offline,
}
