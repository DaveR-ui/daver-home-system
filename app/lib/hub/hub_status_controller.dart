import 'dart:async';

import 'package:flutter/foundation.dart';

import '../hub_status.dart';
import 'hub_address.dart';
import 'hub_client.dart';
import 'hub_discovery.dart';
import 'light_command.dart';
import 'light_command_client.dart';
import 'live_state_client.dart';
import 'token_store.dart';

/// The result of attempting a light command.
///
/// Home Assistant stays the authority (ADR-0005): a [refused] or [busy] command
/// sends nothing and is never queued, and only a [sent] command is applied
/// optimistically.
enum CommandOutcome {
  /// The hub accepted the write; the command is pending confirmation.
  sent,

  /// A command for this entity is already in flight and unconfirmed, so this
  /// one was not sent.
  busy,

  /// The authority is down, so nothing was sent and nothing was queued.
  refused,

  /// The hub rejected the token; the owner must re-enter one.
  needsToken,

  /// The write failed for any other reason.
  failed,
}

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
    this.command,
    this.resolver,
    this.address,
    this.confirmTimeout = const Duration(seconds: 5),
  });

  final HubClient client;
  final TokenStore tokens;

  /// Resolves the hub's base URL. Null means the app uses the clients' own
  /// compile-time default and never searches the LAN.
  final HubAddressResolver? resolver;

  /// The base URL in effect, shared with the clients. Null means "no runtime
  /// addressing".
  final HubAddress? address;

  /// Optional live-state source. When null the controller behaves exactly as
  /// the REST-only increment: probe, snapshot, banner.
  final LiveStateClient? liveState;

  /// Optional write path to Home Assistant's light services. When null the app
  /// has no write path, so every command is refused.
  final LightCommandClient? command;

  /// How long an accepted command may wait for its authoritative confirmation
  /// before a render-only re-read closes the gap.
  ///
  /// Five seconds is chosen because a live confirmation normally lands in well
  /// under a second, while the HTTP request timeout is ten, so this fires well
  /// before a hung write could. Without a deadline, a no-op command that HA
  /// accepts but for which it emits no `state_changed` would leave the
  /// optimistic row and its pending flag stuck forever.
  final Duration confirmTimeout;

  /// Null means connected; the banner is hidden in that case.
  HubStatus? _status = HubStatus.connecting;
  bool _needsToken = false;

  /// Entity ids with an accepted-but-unconfirmed command, and how many, keyed
  /// for the UI's pending indicator.
  ///
  /// The count is the source of truth for [isPending]; the [sendLightCommand]
  /// guard keeps it at one per entity, but counting makes "the last in-flight
  /// command landed" explicit: a first completion must not clear the pending
  /// indicator while a second command for the same entity is still in flight.
  final Map<String, int> _inFlight = <String, int>{};

  /// Per-entity confirmation deadlines, so commands on different entities do
  /// not share one deadline.
  final Map<String, Timer> _confirmTimers = <String, Timer>{};

  /// Render cache keyed by entity id, sorted on read. Never a decision input.
  Map<String, EntitySnapshot> _cache = <String, EntitySnapshot>{};
  bool _disposed = false;

  /// The latest live status; only drives the UI once the probe has passed.
  LiveStatus? _liveStatus;
  StreamSubscription<EntityStateEvent>? _eventsSub;
  StreamSubscription<LiveStatus>? _statusSub;

  /// Counts connect attempts so a slow, stale attempt cannot overwrite a newer one.
  int _attempt = 0;

  /// The one in-flight address resolution, reused for every later attempt so a
  /// token re-entry or a retry never searches the LAN twice.
  Future<HubResolution>? _pendingResolution;

  /// True while the memoized resolution is still running. A refresh must not
  /// discard it: it IS the current platform search, and starting a second one
  /// would install a second subscription for the same LAN.
  bool _resolutionInFlight = false;

  /// The resolution already applied to [address]. Kept so a later attempt
  /// cannot overwrite an address that a late mDNS answer has already promoted.
  HubResolution? _appliedResolution;

  /// The discovery port's late-answer stream, guarded against double
  /// subscription exactly like [_eventsSub].
  StreamSubscription<HubDiscovered>? _lateSub;

  /// True while the NEWEST [connect] body is running, so a late answer can
  /// defer its retry instead of re-entering [connect] re-entrantly.
  ///
  /// Only the newest attempt owns this latch: a superseded attempt must not
  /// release it while a newer one is still running, or a late answer in that
  /// window would start a third, concurrent attempt.
  bool _connecting = false;

  /// An advertisement that arrived while an attempt was running.
  ///
  /// It is deferred, not applied, because the running attempt may still prove
  /// the address it is probing: when it finishes connected, this answer is
  /// discarded and the successful address stays pinned.
  HubDiscovered? _deferredAnswer;

  /// The current reachability; null when connected. The probe result takes
  /// precedence over the live status, and live only starts after the probe
  /// passed, so live can refine a connected hub but never mask a probe failure.
  HubStatus? get status => _status ?? _liveHubStatus;

  bool get isConnected => status == null;

  /// True when no token is stored or the hub rejected it, so the UI should ask
  /// for one.
  bool get needsToken => _needsToken;

  /// The entity ids with an accepted-but-unconfirmed command, for the pending
  /// indicator. Read-only; never a decision input.
  Set<String> get pendingEntities => Set<String>.unmodifiable(
    _inFlight.keys.where((String entityId) => (_inFlight[entityId] ?? 0) > 0),
  );

  /// True while the given entity has an accepted-but-unconfirmed command.
  bool isPending(String entityId) => (_inFlight[entityId] ?? 0) > 0;

  /// True when the hub is reachable and a write path exists. Only then will a
  /// command leave the device; otherwise [sendLightCommand] refuses it.
  bool get canSendCommands => isConnected && command != null;

  /// The render cache, sorted by entity id, for rendering only.
  List<EntitySnapshot> get entities {
    final List<EntitySnapshot> sorted = _cache.values.toList()
      ..sort(
        (EntitySnapshot a, EntitySnapshot b) =>
            a.entityId.compareTo(b.entityId),
      );
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
    _connecting = true;
    try {
      _setStatus(HubStatus.connecting);
      _attachLateAnswers();

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

      // The address is resolved before the probe, so exactly ONE probe runs per
      // attempt: the search is bounded, and a failure is unambiguous.
      if (!await _resolveAddress(attempt)) {
        return; // superseded while the search was running
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
    } finally {
      // Only the newest attempt owns the latch: a superseded attempt leaves it
      // alone, because a newer attempt is still in flight and owns the deferral.
      if (attempt == _attempt) {
        _connecting = false;
        _applyDeferredAnswer();
      }
    }
  }

  /// Resolves the hub address before the probe.
  ///
  /// Returns false when the attempt was superseded while the search ran, so a
  /// stale attempt can never contribute a status.
  Future<bool> _resolveAddress(int attempt) async {
    final HubAddressResolver? resolver = this.resolver;
    final HubAddress? address = this.address;
    if (resolver == null || address == null) {
      return true;
    }
    // Recorded BEFORE the await: an address promoted while the search runs must
    // not be overwritten by this now-stale resolution when it lands.
    final int generation = address.generation;
    final HubResolution resolution = await _resolveOnce(resolver);
    if (attempt != _attempt) {
      return false;
    }
    // The resolution is applied ONCE. A later attempt must not overwrite an
    // address that a late mDNS answer has already promoted.
    if (!identical(_appliedResolution, resolution)) {
      _appliedResolution = resolution;
      if (address.generation == generation) {
        address.update(resolution.baseUrl);
      }
    }
    return true;
  }

  /// The search runs at most ONCE per controller: a token re-entry or a retry
  /// reuses the resolved address instead of searching the LAN again.
  Future<HubResolution> _resolveOnce(HubAddressResolver resolver) {
    final Future<HubResolution>? pending = _pendingResolution;
    if (pending != null) {
      return pending;
    }
    final Future<HubResolution> started = resolver.resolve();
    _pendingResolution = started;
    _resolutionInFlight = true;
    unawaited(
      started.then<void>(
        (HubResolution _) => _resolutionInFlight = false,
        onError: (Object _, StackTrace __) => _resolutionInFlight = false,
      ),
    );
    return started;
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

  /// Re-resolves the hub address after the app returns to the foreground.
  ///
  /// The LAN may have changed while the app was away, so the cached resolution
  /// is dropped and a single bounded search runs again. A CONNECTED hub is
  /// left alone: its address is pinned, and the banner is already hidden.
  Future<void> refreshAddress() async {
    if (status == null) {
      return;
    }
    // An in-flight resolution IS the current platform search: keeping it
    // avoids a second start — and a second subscription — for the same LAN.
    // The LAN change is picked up by the next refresh, when nothing is in
    // flight.
    if (!_resolutionInFlight) {
      _pendingResolution = null;
      _appliedResolution = null;
    }
    await connect();
  }

  /// Sends a light command over the write path, then applies it optimistically.
  ///
  /// Refuses (and sends nothing) when the hub is not connected or there is no
  /// write path: a command is never silently queued while the authority is down
  /// (ADR-0005). A command for an entity that already has one in flight is
  /// refused too ([CommandOutcome.busy]) so a rapid second tap cannot race the
  /// first. On success the accepted write is applied optimistically, with each
  /// row kept at `lastUpdated: null` so the authoritative `state_changed` always
  /// wins the ordering guard; the row is confirmed by the next live event or,
  /// without a live client, by a re-read.
  Future<CommandOutcome> sendLightCommand(LightCommand cmd) async {
    final LightCommandClient? commandClient = command;
    if (!isConnected || commandClient == null) {
      return CommandOutcome.refused;
    }
    // One command in flight per entity: a rapid second tap must not race the
    // first, and Home Assistant must not receive a burst for the same write.
    if (isPending(cmd.entityId)) {
      return CommandOutcome.busy;
    }
    _inFlight[cmd.entityId] = (_inFlight[cmd.entityId] ?? 0) + 1;
    _notify();
    try {
      await commandClient.sendLightCommand(cmd);
    } on TokenRejectedException {
      _needsToken = true;
      _finishCommand(cmd.entityId);
      _notify();
      return CommandOutcome.needsToken;
    } on Object {
      _finishCommand(cmd.entityId);
      _notify();
      return CommandOutcome.failed;
    }

    _applyOptimistic(cmd);
    if (liveState == null) {
      await _confirmByReRead(cmd.entityId);
    } else {
      // A live client cannot rely on the `state_changed` alone, so arm the
      // deadline and return without awaiting it.
      _armConfirmTimer(cmd.entityId);
    }
    return CommandOutcome.sent;
  }

  /// Writes the accepted command into the render cache as a transient hint.
  ///
  /// Home Assistant stays the state authority (ADR-0005): the row is a render
  /// hint only, kept at `lastUpdated: null` so the authoritative `state_changed`
  /// or re-read always overwrites it. Attributes are MERGED, not replaced: a
  /// `turn_off` or a brightness-only `turn_on` must not wipe the cached colour,
  /// and a colour-only `turn_on` must not wipe the cached brightness. A
  /// `toggle`'s resulting state is unknown until HA confirms it, so it is left
  /// untouched.
  void _applyOptimistic(LightCommand cmd) {
    switch (cmd.service) {
      case LightService.turnOn:
        _cache[cmd.entityId] = EntitySnapshot(
          entityId: cmd.entityId,
          state: 'on',
          attributes: _mergedAttributes(cmd),
          lastUpdated: null,
        );
      case LightService.turnOff:
        _cache[cmd.entityId] = EntitySnapshot(
          entityId: cmd.entityId,
          state: 'off',
          attributes: _mergedAttributes(cmd),
          lastUpdated: null,
        );
      case LightService.toggle:
        return;
    }
    liveState?.setTrackedEntities(_cache.keys);
    _notify();
  }

  /// Merges the command's attributes onto the entity's currently cached
  /// attributes, so the optimism keeps the keys the command does not set.
  ///
  /// Starts from a copy (a null-safe no-op when the entity is not cached yet),
  /// normalizes any cached `rgb_color` to `List<int>`, then overwrites
  /// `brightness`/`rgb_color` only when the command carries them. A `turn_off`
  /// carries neither, so the cached attributes survive untouched.
  Map<String, dynamic> _mergedAttributes(LightCommand cmd) {
    final Map<String, dynamic> merged = <String, dynamic>{
      ...?_cache[cmd.entityId]?.attributes,
    };
    final List<int>? cachedColor = _normalizeRgbColor(merged['rgb_color']);
    if (cachedColor != null) {
      merged['rgb_color'] = cachedColor;
    }
    if (cmd.brightness != null) {
      merged['brightness'] = cmd.brightness;
    }
    if (cmd.rgbColor != null) {
      merged['rgb_color'] = cmd.rgbColor;
    }
    return merged;
  }

  /// Normalizes a cached `rgb_color` to `List<int>`.
  ///
  /// HA's JSON decodes the colour as a `List<dynamic>` of numbers, while a
  /// command carries `List<int>`; the render cache must keep one shape. A value
  /// that is not a numeric list returns null so the caller keeps the raw value
  /// unchanged — never inventing or dropping what the authority sent.
  static List<int>? _normalizeRgbColor(Object? value) {
    if (value is! List) {
      return null;
    }
    final List<int> color = <int>[];
    for (final Object? channel in value) {
      if (channel is! num) {
        return null;
      }
      color.add(channel.toInt());
    }
    return color;
  }

  /// Decrements the in-flight count for [entityId], removing the entry once the
  /// last accepted command has landed. Used by the failure paths, where the
  /// authority never confirmed the write.
  void _finishCommand(String entityId) {
    final int count = _inFlight[entityId] ?? 0;
    if (count <= 1) {
      _inFlight.remove(entityId);
    } else {
      _inFlight[entityId] = count - 1;
    }
  }

  /// Clears every in-flight command for [entityId].
  ///
  /// Used by the authoritative confirmations — the live `state_changed` handler
  /// and [_confirmByReRead] — which confirm every in-flight command for the
  /// entity at once, so the count drops straight to zero. Callers notify.
  void _clearPending(String entityId) {
    _inFlight.remove(entityId);
  }

  /// Arms the confirmation deadline for [entityId], replacing any existing one.
  ///
  /// A live command cannot wait on a `state_changed` alone: a no-op command that
  /// HA accepts emits no event, so the deadline forces the same render-only
  /// re-read the REST-only path uses.
  void _armConfirmTimer(String entityId) {
    _cancelConfirmTimer(entityId);
    _confirmTimers[entityId] = Timer(confirmTimeout, () {
      _confirmTimers.remove(entityId);
      unawaited(_confirmByReRead(entityId));
    });
  }

  /// Cancels and drops the confirmation deadline for [entityId], if any.
  void _cancelConfirmTimer(String entityId) {
    _confirmTimers.remove(entityId)?.cancel();
  }

  /// Confirms a command by re-reading the entity: the REST-only path and the
  /// deadline fallback. A failed re-read leaves the cache as-is, and a row the
  /// ordering guard rejects is dropped; the pending flag always clears.
  Future<void> _confirmByReRead(String entityId) async {
    _cancelConfirmTimer(entityId);
    try {
      _applyAuthoritativeRow(await client.fetchEntity(entityId));
    } on Object {
      // Deliberately ignored: the re-read is a render-only confirmation.
    }
    _clearPending(entityId);
    _notify();
  }

  /// Writes an authoritative row — the re-read of one entity — into the render
  /// cache under the same ordering guard a live event uses. The re-read runs
  /// concurrently with the live stream, so a row fetched before a newer
  /// `state_changed` landed must not overwrite it.
  void _applyAuthoritativeRow(EntitySnapshot snapshot) {
    final EntitySnapshot? cached = _cache[snapshot.entityId];
    if (cached != null &&
        !_isAuthoritativeRow(snapshot.lastUpdated, cached.lastUpdated)) {
      return;
    }
    _cache[snapshot.entityId] = snapshot;
  }

  /// Whether an authoritative row carrying [incoming] may replace a cached row
  /// stamped [existing]. A missing row, or a row HA left undated, is always
  /// applied; equal timestamps are a duplicate and an older one is
  /// out-of-order, so both are dropped and a stale render cannot overwrite a
  /// newer one.
  static bool _isAuthoritativeRow(DateTime? incoming, DateTime? existing) =>
      incoming == null || existing == null || incoming.isAfter(existing);

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

  /// Subscribes to the discovery port's late-answer stream. Guarded so a later
  /// [connect] cannot double-subscribe, exactly like [_attachLive].
  void _attachLateAnswers() {
    final HubAddressResolver? resolver = this.resolver;
    if (resolver == null || _lateSub != null) {
      return;
    }
    _lateSub = resolver.discovery.lateAnswers.listen(_onLateAnswer);
  }

  /// Handles an advertisement that arrived after the search resolved.
  ///
  /// While an attempt is running the answer is deferred: the running attempt
  /// may still prove its address, and applying the answer immediately would
  /// move the clients mid-probe. Otherwise the answer is decided right away.
  void _onLateAnswer(HubDiscovered hub) {
    if (_disposed) {
      return;
    }
    if (_connecting) {
      _deferredAnswer = hub;
      return;
    }
    _adoptAnswer(hub);
  }

  /// Applies a deferred answer once the newest attempt has finished.
  ///
  /// Always called after the latch is released, so it may start one new
  /// attempt. A connected hub discards the answer instead: the address that
  /// probed successfully stays pinned.
  void _applyDeferredAnswer() {
    final HubDiscovered? hub = _deferredAnswer;
    _deferredAnswer = null;
    if (hub == null || _disposed) {
      return;
    }
    _adoptAnswer(hub);
  }

  /// Adopts [hub] when the app is not connected, then starts ONE attempt.
  ///
  /// A CONNECTED hub needs no second probe: `status == null` means the banner
  /// is hidden, and moving the REST client to another host while the live
  /// socket stays on this one would split the app across two hubs. An
  /// unchanged address causes no attempt at all.
  void _adoptAnswer(HubDiscovered hub) {
    final HubAddress? address = this.address;
    if (address == null || status == null) {
      return;
    }
    if (address.update(hub.baseUrl)) {
      unawaited(connect());
    }
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
    if (cached != null && !_isAuthoritativeRow(incoming, existing)) {
      return;
    }

    _cache[event.entityId] = EntitySnapshot(
      entityId: event.entityId,
      state: event.state,
      attributes: event.attributes,
      lastUpdated: incoming,
    );
    // An authoritative row confirms any pending command for this entity, so
    // drop both the pending count and the confirmation deadline: a needless
    // re-read later would only repeat what HA already sent.
    _clearPending(event.entityId);
    _cancelConfirmTimer(event.entityId);
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
    _lateSub?.cancel();
    _eventsSub = null;
    _statusSub = null;
    _lateSub = null;
    // A pending confirmation timer would otherwise fire after disposal and keep
    // the test binding complaining about an outstanding timer.
    for (final Timer timer in _confirmTimers.values) {
      timer.cancel();
    }
    _confirmTimers.clear();
    final LiveStateClient? live = liveState;
    if (live != null) {
      unawaited(live.stop());
    }
    super.dispose();
  }
}
