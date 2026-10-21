import 'dart:async';
import 'dart:io';

import 'package:nsd/nsd.dart' as nsd;

import 'hub_address.dart';
import 'hub_discovery.dart';

/// The service type Home Assistant advertises over mDNS.
const String homeAssistantServiceType = '_home-assistant._tcp';

/// Home Assistant's REST port, used when the platform omits `Service.port`.
const int homeAssistantHubPort = 8123;

/// The `nsd` surface the adapter needs, injected so no test ever reaches the
/// platform channel.
abstract interface class NsdRunner {
  Future<NsdSearch> search(String serviceType);
}

/// One running platform search.
abstract interface class NsdSearch {
  /// The advertisements seen so far, and the ones that arrive later.
  Stream<HubDiscovered> get services;

  Future<void> stop();
}

/// The production [HubDiscovery] over `package:nsd`.
///
/// The plugin lives behind [NsdRunner] so this class is entirely testable with
/// a fake: `nsd` throws `MissingPluginException` off-device, and no test may
/// ever reach the platform channel. Every platform failure is folded into a
/// [HubDiscoveryResult]; nothing here throws.
final class NsdHubDiscovery implements HubDiscovery {
  NsdHubDiscovery({
    NsdRunner? runner,
    this.serviceType = homeAssistantServiceType,
  }) : _runner = runner ?? const PackageNsdRunner();

  final NsdRunner _runner;

  /// The service type to search for; injectable for a different HA deployment.
  final String serviceType;

  /// Late advertisements are broadcast: subscribers attach at any time and the
  /// stream carries every [HubDiscovered] that arrives after `discover`
  /// resolved. It stays silent until a search starts and survives `stop()`:
  /// stopping and restarting the platform search never closes it.
  final StreamController<HubDiscovered> _lateAnswers =
      StreamController<HubDiscovered>.broadcast();

  Future<NsdSearch>? _starting;
  NsdSearch? _search;
  StreamSubscription<HubDiscovered>? _subscription;

  /// The `discover` calls waiting for the first advertisement. More than one
  /// can wait: two calls that shared the platform start must both be
  /// answered, or the first one starves until its deadline.
  final Set<Completer<HubDiscoveryResult>> _pending =
      <Completer<HubDiscoveryResult>>{};
  bool _ended = false;
  bool _failed = false;

  /// Bumped by every `stop()`, so a platform start that was already in flight
  /// cannot install its search after the adapter was stopped.
  int _generation = 0;

  @override
  Stream<HubDiscovered> get lateAnswers => _lateAnswers.stream;

  @override
  Future<HubDiscoveryResult> discover({required Duration timeout}) async {
    if (timeout <= Duration.zero) {
      return const HubDiscoveryNotFound(HubNotFoundReason.timeout);
    }

    // Registered BEFORE the platform search starts: the adapter may flush an
    // advertisement that was already collected as soon as the subscription
    // attaches, which can happen before this method resumes from the await.
    final Completer<HubDiscoveryResult> first = Completer<HubDiscoveryResult>();
    _pending.add(first);
    final Stopwatch watch = Stopwatch()..start();

    final NsdSearch? search;
    try {
      search = await _ensureSearch(timeout);
    } on _SearchStartTimeout {
      _clearPending(first);
      return const HubDiscoveryNotFound(HubNotFoundReason.timeout);
    } on Object {
      // A missing plugin, a missing permission, or any other platform failure
      // means the search could not run at all.
      _clearPending(first);
      return const HubDiscoveryNotFound(HubNotFoundReason.pluginUnavailable);
    }
    if (search == null) {
      _clearPending(first);
      return const HubDiscoveryNotFound(HubNotFoundReason.pluginUnavailable);
    }

    // Whatever the start did not use is the budget for the FIRST advertisement.
    final Duration remaining = timeout - watch.elapsed;
    if (first.isCompleted) {
      // The flush delivered an advertisement while the start was resolving.
      _clearPending(first);
      return first.future;
    }
    if (remaining <= Duration.zero) {
      // The start consumed the whole deadline. The search keeps running: a hub
      // that answers late is delivered on [lateAnswers] instead of being lost.
      _clearPending(first);
      return const HubDiscoveryNotFound(HubNotFoundReason.timeout);
    }

    try {
      return await first.future.timeout(
        remaining,
        onTimeout: () {
          // The search keeps running: a hub that answers late is delivered on
          // [lateAnswers] instead of being lost with the deadline.
          _clearPending(first);
          return const HubDiscoveryNotFound(HubNotFoundReason.timeout);
        },
      );
    } finally {
      _clearPending(first);
    }
  }

  @override
  Future<void> stop() async {
    // Not terminal: a later `discover` starts a fresh search. The generation
    // bump makes a start that is still in flight release itself instead of
    // installing a search the app has already asked to stop.
    _generation++;
    _starting = null;
    // A caller still waiting for a first advertisement must not hang once the
    // search is torn down.
    _completePending(
      const HubDiscoveryNotFound(HubNotFoundReason.pluginUnavailable),
    );
    await _releaseSearch();
  }

  /// Starts (or reuses) the platform search, bounded by [timeout].
  ///
  /// Returns null only when [stop] raced the start and the freshly started
  /// search was released again. Throws [_SearchStartTimeout] when the platform
  /// never acknowledges the start, and any other failure when it cannot start.
  Future<NsdSearch?> _ensureSearch(Duration timeout) async {
    NsdSearch? current = _search;
    if (current != null && _ended) {
      // The previous search ended on its own; release it before starting over.
      await _releaseSearch();
      current = null;
    }
    if (current != null) {
      return current;
    }

    final int generation = _generation;
    Future<NsdSearch>? starting = _starting;
    if (starting == null) {
      // `Future.sync` also turns a synchronous throw in a misbehaving runner
      // into a failed future, so nothing here can escape as an exception.
      starting = Future<NsdSearch>.sync(() => _runner.search(serviceType));
      _starting = starting;
    }
    final Future<NsdSearch> start = starting;

    final NsdSearch search;
    try {
      search = await start.timeout(
        timeout,
        onTimeout: () => throw const _SearchStartTimeout(),
      );
    } on _SearchStartTimeout {
      // The native side may still answer eventually. Release that search when
      // it does, or the platform keeps a multicast lock nobody owns.
      unawaited(start.then(_stopQuietly, onError: (Object _) {}));
      rethrow;
    } finally {
      if (identical(_starting, start)) {
        _starting = null;
      }
    }

    if (generation != _generation) {
      // `stop()` ran while the platform was starting: this search belongs to
      // a cycle the app already ended.
      await _stopQuietly(search);
      return null;
    }

    // Install the platform search exactly once. Two callers that shared the
    // platform start must not each install a subscription: the second would
    // leak the first, and every advertisement would be delivered twice.
    if (!identical(_search, search) || _subscription == null) {
      _search = search;
      _ended = false;
      _failed = false;
      _subscription = search.services.listen(
        _onService,
        onError: _onError,
        onDone: _onSearchEnded,
        cancelOnError: true,
      );
    }
    return search;
  }

  /// Releases the current search without touching the late-answer stream, so a
  /// later `discover` can start a fresh one.
  Future<void> _releaseSearch() async {
    final StreamSubscription<HubDiscovered>? subscription = _subscription;
    _subscription = null;
    if (subscription != null) {
      await subscription.cancel();
    }
    final NsdSearch? search = _search;
    _search = null;
    _ended = false;
    _failed = false;
    if (search != null) {
      await _stopQuietly(search);
    }
  }

  /// The first advertisement resolves the pending `discover`; every later one
  /// is a late answer. The search's own replay buffer guarantees that an
  /// advertisement collected before the listener attached is still delivered.
  void _onService(HubDiscovered hub) {
    if (_pending.isNotEmpty) {
      // A copy: clearing [_pending] must not also empty the set being iterated.
      final Set<Completer<HubDiscoveryResult>> waiters =
          <Completer<HubDiscoveryResult>>{..._pending};
      _pending.clear();
      for (final Completer<HubDiscoveryResult> waiter in waiters) {
        if (!waiter.isCompleted) {
          waiter.complete(HubDiscoveryFound(hub));
        }
      }
      return;
    }
    if (!_lateAnswers.isClosed) {
      _lateAnswers.add(hub);
    }
  }

  void _onError(Object error, StackTrace stackTrace) {
    // The platform stream failed: the search could not run to a verdict.
    _failed = true;
    _ended = true;
    _subscription = null;
    _completePending(
      const HubDiscoveryNotFound(HubNotFoundReason.pluginUnavailable),
    );
  }

  void _onSearchEnded() {
    _ended = true;
    _subscription = null;
    _completePending(
      HubDiscoveryNotFound(
        _failed
            ? HubNotFoundReason.pluginUnavailable
            : HubNotFoundReason.noAdvertisement,
      ),
    );
  }

  /// Resolves every waiting `discover` at most once; a no-op when none waits.
  void _completePending(HubDiscoveryResult result) {
    // A copy: clearing [_pending] must not also empty the set being iterated.
    final Set<Completer<HubDiscoveryResult>> waiters =
        <Completer<HubDiscoveryResult>>{..._pending};
    _pending.clear();
    for (final Completer<HubDiscoveryResult> waiter in waiters) {
      if (!waiter.isCompleted) {
        waiter.complete(result);
      }
    }
  }

  /// Clears [completer] as a waiter, but only while it still waits: a newer
  /// `discover` must not lose its own waiter.
  void _clearPending(Completer<HubDiscoveryResult> completer) {
    _pending.remove(completer);
  }

  Future<void> _stopQuietly(NsdSearch search) async {
    try {
      await search.stop();
    } on Object {
      // A platform search that is already gone needs no further action, and
      // stop() on the port must stay safe to call more than once.
    }
  }
}

/// The platform never acknowledged the start of the search before its
/// deadline. A private signal: `discover` maps it onto the typed result.
final class _SearchStartTimeout implements Exception {
  const _SearchStartTimeout();
}

/// The production [NsdRunner]: the only place that touches `package:nsd`.
///
/// Kept deliberately small so [NsdHubDiscovery] — the part with the deadline,
/// the routing, and the failure mapping — never needs the plugin to be tested.
final class PackageNsdRunner implements NsdRunner {
  const PackageNsdRunner({this.ipLookupType = nsd.IpLookupType.v4});

  /// IPv4 lookup is requested so a service that omits `host` can still be
  /// addressed through its first IPv4 entry.
  final nsd.IpLookupType ipLookupType;

  @override
  Future<NsdSearch> search(String serviceType) async {
    final nsd.Discovery discovery = await nsd.startDiscovery(
      serviceType,
      ipLookupType: ipLookupType,
    );
    return PackageNsdSearch(discovery);
  }
}

/// Wraps one platform [nsd.Discovery] as an [NsdSearch].
///
/// `nsd` exposes listeners rather than a stream, so this class owns the
/// translation: found services become [HubDiscovered] values; `lost` service
/// notifications are ignored because the hub's address is still known and
/// re-resolution happens on the next search.
///
/// The broadcast controller drops every event added while it has no listener,
/// and [NsdHubDiscovery] only subscribes after `startDiscovery` has resolved.
/// Advertisements collected before that first subscriber attaches are
/// therefore buffered and flushed from `onListen`, which fires after the
/// subscription is registered.
final class PackageNsdSearch implements NsdSearch {
  PackageNsdSearch(
    this._discovery, {
    Future<void> Function(nsd.Discovery discovery)? stopDiscovery,
  }) : _stopDiscovery = stopDiscovery ?? nsd.stopDiscovery {
    _discovery.addServiceListener(_listener);
    // startDiscovery() may already have collected a service before this
    // listener was attached, so replay what the discovery holds.
    for (final nsd.Service service in _discovery.services) {
      final HubDiscovered? hub = hubDiscoveredFromNsdService(service);
      if (hub != null) {
        _buffer(hub);
      }
    }
  }

  final nsd.Discovery _discovery;

  /// Injected so a test can wrap a hand-built [nsd.Discovery] without reaching
  /// the platform channel through `stopDiscovery`.
  final Future<void> Function(nsd.Discovery discovery) _stopDiscovery;

  late final StreamController<HubDiscovered> _services =
      StreamController<HubDiscovered>.broadcast(onListen: _flush);

  /// One stable reference, because removing a service listener needs the exact
  /// same callback.
  late final nsd.ServiceListener _listener = _onService;

  /// Advertisements not yet handed to a subscriber.
  final List<HubDiscovered> _buffered = <HubDiscovered>[];

  /// Addresses already delivered to a subscriber, so one advertisement is
  /// never delivered twice.
  final Set<String> _delivered = <String>{};

  bool _stopped = false;

  @override
  Stream<HubDiscovered> get services => _services.stream;

  void _onService(nsd.Service service, nsd.ServiceStatus status) {
    if (_stopped || status != nsd.ServiceStatus.found) {
      return;
    }
    final HubDiscovered? hub = hubDiscoveredFromNsdService(service);
    if (hub == null) {
      return;
    }
    if (_services.hasListener) {
      // The flush has already happened: this one is delivered straight away.
      _deliver(hub);
    } else {
      _buffer(hub);
    }
  }

  /// Keeps [hub] until a subscriber attaches. Only an address that was already
  /// delivered is suppressed; an undelivered advertisement must never be
  /// dropped because the constructor merely replayed it.
  void _buffer(HubDiscovered hub) {
    if (_delivered.contains(hub.baseUrl)) {
      return;
    }
    for (final HubDiscovered seen in _buffered) {
      if (seen.baseUrl == hub.baseUrl) {
        return;
      }
    }
    _buffered.add(hub);
  }

  /// Hands the buffered advertisements to the first subscriber. Runs from
  /// `onListen`, after the subscription is registered, so the events reach it.
  void _flush() {
    if (_stopped || _buffered.isEmpty) {
      return;
    }
    final List<HubDiscovered> pending = List<HubDiscovered>.of(_buffered);
    _buffered.clear();
    for (final HubDiscovered hub in pending) {
      _deliver(hub);
    }
  }

  void _deliver(HubDiscovered hub) {
    if (_stopped || _services.isClosed) {
      return;
    }
    if (!_delivered.add(hub.baseUrl)) {
      return;
    }
    _services.add(hub);
  }

  @override
  Future<void> stop() async {
    if (_stopped) {
      return;
    }
    _stopped = true;
    _buffered.clear();
    try {
      _discovery.removeServiceListener(_listener);
      await _stopDiscovery(_discovery);
    } on Object {
      // The platform search may already be gone; stopping stays idempotent.
    }
    if (!_services.isClosed) {
      await _services.close();
    }
  }
}

/// Maps one `nsd` advertisement onto a [HubDiscovered].
///
/// Returns null when the advertisement carries no usable address: a service
/// with neither a host nor an IPv4 address cannot be addressed.
///
/// The advertised `host` is preferred; an empty host falls back to the first
/// IPv4 entry of `service.addresses`. The port is `service.port`, or
/// [homeAssistantHubPort] when the platform omits it. An IPv6 literal gets
/// brackets so it can sit in a URL authority, and the `baseUrl` is
/// `http://<authority>:<port>`, normalized with [normalizeHubBaseUrl]. The
/// `name` falls back to the host when the service has no name.
HubDiscovered? hubDiscoveredFromNsdService(nsd.Service service) {
  String host = service.host?.trim() ?? '';
  if (host.isEmpty) {
    for (final InternetAddress address
        in service.addresses ?? const <InternetAddress>[]) {
      if (address.type == InternetAddressType.IPv4) {
        host = address.address;
        break;
      }
    }
  }
  if (host.isEmpty) {
    return null;
  }

  final int port = service.port ?? homeAssistantHubPort;
  // An IPv6 literal needs brackets before it can sit in a URL authority.
  final String authority = host.contains(':') && !host.startsWith('[')
      ? '[$host]'
      : host;
  final String baseUrl = normalizeHubBaseUrl('http://$authority:$port');
  if (baseUrl.isEmpty) {
    return null;
  }
  final String? name = service.name;
  return HubDiscovered(
    name: name == null || name.trim().isEmpty ? host : name,
    host: host,
    port: port,
    baseUrl: baseUrl,
  );
}
