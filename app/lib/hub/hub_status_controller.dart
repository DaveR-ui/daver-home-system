import 'dart:async';

import 'package:flutter/foundation.dart';

import '../hub_status.dart';
import 'hub_client.dart';
import 'live_state_client.dart';
import 'token_store.dart';

/// Drives the app's [HubStatus] from the real probe, snapshot, and live
/// WebSocket state.
///
/// The status is the only reachability model the UI reads. [_cache] is a
/// render cache of the last good snapshot (plus live updates), never a second
/// source of truth: Home Assistant stays the state authority (ADR-0005), so it
/// is used to render and nothing else.
final class HubStatusController extends ChangeNotifier {
  HubStatusController({
    required this.client,
    required this.tokens,
    this.liveState,
  });

  final HubClient client;
  final TokenStore tokens;

  /// Optional live-state source. When null the controller behaves exactly as
  /// the REST-only increment: probe, snapshot, banner.
  final LiveStateClient? liveState;

  /// Null means connected; the banner is hidden in that case.
  HubStatus? _status = HubStatus.connecting;
  bool _needsToken = false;

  /// Render cache keyed by entity id, sorted on read. Never a decision input.
  Map<String, EntitySnapshot> _cache = <String, EntitySnapshot>{};
  bool _disposed = false;

  /// The latest live status; only drives the UI once the probe has passed.
  LiveStatus? _liveStatus;
  StreamSubscription<EntityStateEvent>? _eventsSub;
  StreamSubscription<LiveStatus>? _statusSub;

  /// Counts connect attempts so a slow, stale attempt cannot overwrite a newer one.
  int _attempt = 0;

  /// The current reachability; null when connected. The probe result takes
  /// precedence over the live status, and live only starts after the probe
  /// passed, so live can refine a connected hub but never mask a probe failure.
  HubStatus? get status => _status ?? _liveHubStatus;

  bool get isConnected => status == null;

  /// True when no token is stored or the hub rejected it, so the UI should ask
  /// for one.
  bool get needsToken => _needsToken;

  /// The render cache, sorted by entity id, for rendering only.
  List<EntitySnapshot> get entities {
    final List<EntitySnapshot> sorted = _cache.values.toList()
      ..sort((EntitySnapshot a, EntitySnapshot b) =>
          a.entityId.compareTo(b.entityId));
    return List<EntitySnapshot>.unmodifiable(sorted);
  }

  HubStatus? get _liveHubStatus => switch (_liveStatus) {
        null => null,
        LiveStatus.connecting => HubStatus.connecting,
        LiveStatus.reconnecting => HubStatus.connecting,
        LiveStatus.connected => null,
        LiveStatus.hubUnavailable => HubStatus.hubUnavailable,
        LiveStatus.offline => HubStatus.offline,
        LiveStatus.tokenRejected => HubStatus.hubUnavailable,
      };

  /// Probes the hub and, when it answers, caches the entity snapshot and
  /// attaches the live-state stream.
  Future<void> connect() async {
    final int attempt = ++_attempt;
    _setStatus(HubStatus.connecting);

    final String? token;
    try {
      token = await tokens.readToken();
    } on Object {
      _finish(attempt, HubStatus.hubUnavailable);
      return;
    }
    if (attempt != _attempt) {
      return;
    }
    if (token == null || token.isEmpty) {
      _finish(attempt, HubStatus.hubUnavailable, needsToken: true);
      return;
    }

    try {
      await client.probeHub();
    } on DeviceOfflineException {
      _finish(attempt, HubStatus.offline);
      return;
    } on TokenRejectedException {
      // Must precede the generic branch: a rejected token is re-auth, not a retry.
      _finish(attempt, HubStatus.hubUnavailable, needsToken: true);
      return;
    } on Object {
      // Unknown failures count as unavailable: reachability is unproven.
      _finish(attempt, HubStatus.hubUnavailable);
      return;
    }
    if (attempt != _attempt) {
      return;
    }

    // The probe succeeded; live state may now refine the connected hub.
    _attachLive();

    // The probe succeeded, so the hub is connected even if the snapshot fails.
    // The previous cache is kept; the banner is hidden only on a connected hub.
    try {
      final List<EntitySnapshot> states = await client.fetchStates();
      if (attempt != _attempt) {
        return;
      }
      _cache = <String, EntitySnapshot>{
        for (final EntitySnapshot state in states) state.entityId: state,
      };
    } on Object {
      // Deliberately ignored: the snapshot is a cache, and the probe already passed.
    }
    if (attempt != _attempt) {
      return;
    }

    final LiveStateClient? live = liveState;
    if (live != null) {
      live.setTrackedEntities(_cache.keys);
      unawaited(live.start());
    }
    _finish(attempt, null, needsToken: false);
  }

  /// Saves a freshly entered token, then re-runs [connect] so the probe uses it.
  Future<void> saveToken(String token) async {
    final String trimmed = token.trim();
    if (trimmed.isEmpty) {
      return;
    }
    try {
      await tokens.writeToken(trimmed);
    } on Object {
      _attempt++;
      _setStatus(HubStatus.hubUnavailable);
      return;
    }
    await connect();
  }

  /// Subscribes to the live streams once the probe has passed. Guarded so a
  /// later [connect] cannot double-subscribe.
  void _attachLive() {
    final LiveStateClient? live = liveState;
    if (live == null || _eventsSub != null) {
      return;
    }
    _eventsSub = live.events.listen(_onLiveEvent);
    _statusSub = live.status.listen(_onLiveStatus);
  }

  void _onLiveEvent(EntityStateEvent event) {
    if (_disposed) {
      return;
    }
    final EntitySnapshot? cached = _cache[event.entityId];
    final DateTime? incoming = event.lastUpdated;
    final DateTime? existing = cached?.lastUpdated;

    // Apply only a genuinely newer row: a missing row, or a row HA left
    // undated. Equal timestamps are a duplicate; older is out-of-order. Both
    // are dropped so a stale render cannot overwrite a newer one.
    final bool apply = cached == null ||
        incoming == null ||
        existing == null ||
        incoming.isAfter(existing);
    if (!apply) {
      return;
    }

    _cache[event.entityId] = EntitySnapshot(
      entityId: event.entityId,
      state: event.state,
      attributes: event.attributes,
      lastUpdated: incoming,
    );
    liveState?.setTrackedEntities(_cache.keys);
    _notify();
  }

  void _onLiveStatus(LiveStatus live) {
    if (_disposed) {
      return;
    }
    // The live path may only ADD the re-auth requirement: clearing it stays the
    // probe's job (`_finish(..., needsToken: false)`), so a live `connected`
    // cannot briefly hide the re-auth surface while the probe still reports the
    // hub unavailable.
    if (live == LiveStatus.tokenRejected) {
      _needsToken = true;
    }
    _liveStatus = live;
    _notify();
  }

  void _setStatus(HubStatus? status) {
    _status = status;
    _notify();
  }

  /// Applies a result only when it is still the latest attempt, so a
  /// superseded attempt can never flip [needsToken] or the status. A null
  /// [needsToken] leaves the flag unchanged.
  void _finish(int attempt, HubStatus? status, {bool? needsToken}) {
    if (attempt != _attempt) {
      return;
    }
    if (needsToken != null) {
      _needsToken = needsToken;
    }
    _setStatus(status);
  }

  void _notify() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _eventsSub?.cancel();
    _statusSub?.cancel();
    _eventsSub = null;
    _statusSub = null;
    final LiveStateClient? live = liveState;
    if (live != null) {
      unawaited(live.stop());
    }
    super.dispose();
  }
}
