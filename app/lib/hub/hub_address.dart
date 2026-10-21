import 'hub_discovery.dart';

/// Reads the hub base URL in effect. Called at USE time, never cached by the
/// caller: the address can change after the clients are built.
typedef HubAddressReader = String Function();

/// Where the effective hub base URL came from.
enum HubAddressSource {
  /// An explicitly supplied `--dart-define=HUB_BASE_URL=…`.
  explicitOverride,

  /// An mDNS advertisement.
  mdns,

  /// The static fallback host.
  staticFallback,
}

/// The outcome of resolving the hub's base URL.
final class HubResolution {
  const HubResolution({required this.baseUrl, required this.source, this.miss});

  final String baseUrl;
  final HubAddressSource source;

  /// Set when the resolution fell back to the static host: the reason the
  /// mDNS search produced no hub. It is an OBSERVATION on a successful
  /// (fallback) resolution — never an error, and it must never paint a
  /// status on its own.
  final HubDiscoveryNotFound? miss;
}

/// The hub base URL in effect, shared by every client that talks to the hub.
///
/// Mutable on purpose: the platform's mDNS responder only answers a query
/// that is already running, so the address cannot be a compile-time constant
/// and cannot be known before the app has started. The REST transport reads
/// it once per request and the WebSocket client once per connection attempt,
/// so a late address takes effect without rebuilding either client — the same
/// seam the token reader already uses.
final class HubAddress {
  HubAddress(String baseUrl) : _baseUrl = normalizeHubBaseUrl(baseUrl);

  String _baseUrl;
  int _generation = 0;

  /// The base URL in effect.
  String get baseUrl => _baseUrl;

  /// Incremented on every accepted change, so a caller that awaited
  /// something can tell whether the address moved while it waited.
  int get generation => _generation;

  /// The tear-off handed to the clients. Call at use time, never cache it.
  HubAddressReader get read =>
      () => _baseUrl;

  /// Adopts [baseUrl] as the address in effect.
  ///
  /// Returns false when the value is not a usable base URL or when it equals
  /// the current one — so a late advertisement of the same hub never causes
  /// a spurious change.
  bool update(String baseUrl) {
    final String normalized = normalizeHubBaseUrl(baseUrl);
    if (normalized.isEmpty || normalized == _baseUrl) {
      return false;
    }
    _baseUrl = normalized;
    _generation++;
    return true;
  }
}

/// Normalizes a hub base URL to the canonical form `scheme://host[:port]`.
///
/// A usable base URL is a scheme, a host and an optional port and nothing
/// else: the REST transport concatenates `'$baseUrl$path'`, so credentials, a
/// path, a query or a fragment would silently produce a broken request URL.
/// The returned value is rebuilt from the parsed components and has no
/// trailing slash, so `http://host:8123/` and `http://host:8123` normalize to
/// the same string. Returns the EMPTY STRING when the value is not usable.
String normalizeHubBaseUrl(String baseUrl) {
  final String trimmed = baseUrl.trim();
  if (trimmed.isEmpty) {
    return '';
  }
  final Uri? uri = Uri.tryParse(trimmed);
  if (uri == null) {
    return '';
  }
  if (uri.scheme != 'http' && uri.scheme != 'https') {
    return '';
  }
  if (uri.host.isEmpty) {
    return '';
  }
  if (uri.userInfo.isNotEmpty) {
    return '';
  }
  // A path of exactly `/` is the same as no path; anything else would be
  // appended to the request path.
  if (uri.path.isNotEmpty && uri.path != '/') {
    return '';
  }
  if (uri.hasQuery || uri.hasFragment) {
    return '';
  }
  // `Uri.host` strips the brackets from an IPv6 literal, so put them back
  // before the host is used as a URL authority.
  final String host = uri.host.contains(':') ? '[${uri.host}]' : uri.host;
  final String port = uri.hasPort ? ':${uri.port}' : '';
  return '${uri.scheme}://$host$port';
}

/// The documented default hub host, independent of any build-time override.
///
/// It is a separate constant from the build-time override so an override that
/// is present but EMPTY (`--dart-define=HUB_BASE_URL=`) can never leave the
/// app without an address.
const String defaultHubHost = 'http://homeassistant.local:8123';

/// The base URL to use for [candidate]: the candidate itself when it is a
/// usable address, else the documented default.
///
/// An override or a fallback that is present but EMPTY or malformed
/// (`--dart-define=HUB_BASE_URL=`) must never leave the app without an
/// address.
String usableHubBaseUrl(String candidate) {
  final String normalized = normalizeHubBaseUrl(candidate);
  return normalized.isEmpty ? defaultHubHost : normalized;
}

/// The address-precedence rule, as a pure resolver.
///
/// Precedence, in order:
/// 1. An explicitly supplied `--dart-define=HUB_BASE_URL=…` wins outright and
///    the mDNS search is SKIPPED entirely.
/// 2. Otherwise the mDNS search decides.
/// 3. Otherwise the static fallback host is used, and the miss is reported
///    as an observation on the resolution.
///
/// The override is detected with a `bool` PARAMETER, not a compile-time
/// constant read inside the resolver, so every arm is unit-testable without
/// a `--dart-define` (which is impossible under `flutter test`).
final class HubAddressResolver {
  HubAddressResolver({
    required this.hasOverride,
    required this.overrideBaseUrl,
    required this.fallbackBaseUrl,
    required this.discovery,
    this.timeout = const Duration(seconds: 3),
  });

  /// True when the build supplied an explicit override.
  final bool hasOverride;

  /// The override's URL. Empty or whitespace means "no usable override".
  final String overrideBaseUrl;

  /// The static fallback host, used when no override and no advertisement.
  final String fallbackBaseUrl;

  /// The port over the platform's mDNS search.
  final HubDiscovery discovery;

  /// How long the mDNS search may run.
  final Duration timeout;

  /// Resolves the hub's base URL. Never throws: a failed search is a
  /// [HubDiscoveryNotFound] carried on the resolution, not an exception.
  Future<HubResolution> resolve() async {
    if (hasOverride) {
      final String override = normalizeHubBaseUrl(overrideBaseUrl);
      // A present-but-empty `--dart-define` is not an override; fall through
      // to the search exactly like an absent one.
      if (override.isNotEmpty) {
        return HubResolution(
          baseUrl: override,
          source: HubAddressSource.explicitOverride,
        );
      }
    }

    final HubDiscoveryResult result = await _search();
    if (result is HubDiscoveryFound) {
      return HubResolution(
        baseUrl: result.hub.baseUrl,
        source: HubAddressSource.mdns,
      );
    }
    // The port contracts not to throw; the adapter maps its failures. This
    // narrows the sealed result for the compiler, and the fallback carries the
    // observation without ever turning it into an error.
    final HubDiscoveryNotFound miss = result as HubDiscoveryNotFound;
    return HubResolution(
      baseUrl: usableHubBaseUrl(fallbackBaseUrl),
      source: HubAddressSource.staticFallback,
      miss: miss,
    );
  }

  /// Runs the search behind the port. A misbehaving implementation must not
  /// crash startup, so an unexpected throw is treated as a search that could
  /// not run at all.
  Future<HubDiscoveryResult> _search() async {
    try {
      return await discovery.discover(timeout: timeout);
    } on Object {
      return const HubDiscoveryNotFound(HubNotFoundReason.pluginUnavailable);
    }
  }
}
