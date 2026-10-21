/// Why a discovery search produced no hub.
enum HubNotFoundReason {
  /// The search ran to its deadline without an advertisement.
  timeout,

  /// The platform answered, but no Home Assistant advertisement was seen.
  noAdvertisement,

  /// The platform search could not run at all: the plugin is unavailable
  /// (off-device), a permission is missing, or multicast is blocked.
  pluginUnavailable,
}

/// A hub advertisement found by the platform's mDNS search.
final class HubDiscovered {
  const HubDiscovered({
    required this.name,
    required this.host,
    required this.port,
    required this.baseUrl,
  });

  final String name;
  final String host;
  final int port;

  /// The REST base URL for the discovered hub, e.g. `http://192.168.1.50:8123`.
  final String baseUrl;
}

/// The outcome of one discovery search. Typed: never an exception.
///
/// "Not found" is an expected outcome, not an error: a network that blocks
/// multicast still has to fall back to the static host, and a missing plugin
/// off-device must not crash startup.
sealed class HubDiscoveryResult {
  const HubDiscoveryResult();
}

/// A Home Assistant advertisement was found.
final class HubDiscoveryFound extends HubDiscoveryResult {
  const HubDiscoveryFound(this.hub);

  final HubDiscovered hub;
}

/// The search produced no hub. [reason] says why.
final class HubDiscoveryNotFound extends HubDiscoveryResult {
  const HubDiscoveryNotFound(this.reason);

  final HubNotFoundReason reason;
}

/// The app's port over the platform's mDNS search. Fake-able in tests; the
/// production implementation is `NsdHubDiscovery`.
abstract interface class HubDiscovery {
  /// Searches for a Home Assistant advertisement, bounded by [timeout].
  ///
  /// Never throws: every failure — a timeout, an empty result, a missing
  /// plugin, a blocked multicast — maps onto [HubDiscoveryNotFound].
  Future<HubDiscoveryResult> discover({required Duration timeout});

  /// Advertisements that arrive AFTER [discover] returned. A search that
  /// timed out may still see the hub later; this is how a late answer is
  /// delivered without a second search.
  Stream<HubDiscovered> get lateAnswers;

  /// Stops the platform search and releases its resources.
  Future<void> stop();
}
