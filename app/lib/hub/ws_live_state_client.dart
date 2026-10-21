import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:web_socket_channel/web_socket_channel.dart';

import 'hub_address.dart';
import 'hub_client.dart';
import 'live_state_client.dart';

/// Base backoff delay for the first reconnect attempt.
const int _baseBackoffMs = 1000;

/// Upper bound on the backoff delay, so a long outage never spins hot.
const int _maxBackoffMs = 30000;

/// Sentinel returned by [_WsLiveStateClient._readMessage] when a message could
/// not be read (stream ended, errored, or timed out).
class _NoMessage {
  const _NoMessage();
}

const _NoMessage _noMessage = _NoMessage();

/// How a single connection attempt ended.
enum _AttemptKind {
  /// The connection was established and then dropped.
  dropped,

  /// The attempt never reached a connected-and-subscribed state.
  retry,

  /// Home Assistant rejected the stored token; stop and ask for a new one.
  tokenRejected,
}

/// The outcome of one connection attempt.
class _AttemptResult {
  const _AttemptResult(this.kind, [this.status]);

  final _AttemptKind kind;

  /// The status to emit for a [ _AttemptKind.retry ]; null means hubUnavailable.
  final LiveStatus? status;
}

/// The production [LiveStateClient] over `package:web_socket_channel`.
///
/// The channel factory, delay, and jitter are injected so tests never open a
/// socket and never wait on a real timer. The token is read fresh on every
/// attempt and appears on the wire exactly once, in the `auth` message.
final class WsLiveStateClient implements LiveStateClient {
  WsLiveStateClient({
    required this.baseUrlReader,
    required this.tokenReader,
    required this.hubClient,
    Future<WebSocketChannel> Function(Uri uri)? channelFactory,
    Future<void> Function(Duration duration)? delay,
    double Function()? jitter,
    this.connectTimeout = const Duration(seconds: 10),
  })  : _channelFactory =
            channelFactory ?? ((Uri uri) async => WebSocketChannel.connect(uri)),
        _delay = delay ?? ((Duration duration) => Future<void>.delayed(duration)),
        _jitter = jitter ?? math.Random().nextDouble;

  /// Reads the hub base URL (`http` or `ws`) once per connection attempt, so
  /// every attempt follows the address in effect: a late mDNS answer is picked
  /// up without rebuilding this client. The WebSocket URI is derived
  /// internally.
  final HubAddressReader baseUrlReader;

  /// Reads the long-lived token on every attempt, so a token saved after
  /// startup is picked up without rebuilding the client.
  final Future<String?> Function() tokenReader;

  /// Used to re-read the tracked entities after a reconnect. This closes the
  /// gap the disconnect left; it is a render-cache refresh, never a decision
  /// input (ADR-0005).
  final HubClient hubClient;

  /// Upper bound while opening the socket or waiting for a handshake message.
  final Duration connectTimeout;

  /// Upper bound on the best-effort cleanup awaits. A peer that vanished
  /// mid-stream can leave `StreamIterator.cancel()` or `sink.close()` pending
  /// forever; without a bound the attempt's `finally` would never return and
  /// the reconnect loop would stop. A shorter injected [connectTimeout] (as in
  /// tests) tightens the bound; the default is capped so a killed hub never
  /// stalls reconnection for the whole handshake budget.
  Duration get _cleanupTimeout {
    const Duration cap = Duration(seconds: 2);
    return connectTimeout < cap ? connectTimeout : cap;
  }

  final Future<WebSocketChannel> Function(Uri uri) _channelFactory;
  final Future<void> Function(Duration duration) _delay;
  final double Function() _jitter;

  final StreamController<EntityStateEvent> _events =
      StreamController<EntityStateEvent>.broadcast();
  final StreamController<LiveStatus> _status =
      StreamController<LiveStatus>.broadcast();

  bool _running = false;
  bool _stopped = false;
  int _nextId = 1;
  int _backoff = 0;
  Set<String> _tracked = const <String>{};
  LiveStatus _openFailureStatus = LiveStatus.hubUnavailable;
  WebSocketChannel? _activeChannel;
  StreamIterator<dynamic>? _activeMessages;

  /// Tracks which channels were already closed, so `stop()` and the attempt's
  /// own cleanup cannot close the same sink twice. The owning attempt removes
  /// its entry when it finishes, so the set never grows across attempts.
  final Set<Object> _closedChannels = <Object>{};

  @override
  Stream<EntityStateEvent> get events => _events.stream;

  @override
  Stream<LiveStatus> get status => _status.stream;

  @override
  void setTrackedEntities(Iterable<String> entityIds) {
    _tracked = Set<String>.unmodifiable(entityIds);
  }

  @override
  Future<void> start() async {
    if (_running || _stopped) {
      return;
    }
    _running = true;
    _backoff = 0;
    _emitStatus(LiveStatus.connecting);
    // Fire-and-forget: the loop keeps reconnecting until stop() is called.
    unawaited(_run());
  }

  @override
  Future<void> stop() async {
    if (_stopped) {
      return;
    }
    _stopped = true;
    _running = false;

    final StreamIterator<dynamic>? messages = _activeMessages;
    _activeMessages = null;
    if (messages != null) {
      await _cancelMessages(messages);
    }

    final WebSocketChannel? channel = _activeChannel;
    _activeChannel = null;
    if (channel != null) {
      await _closeSink(channel);
    }

    if (!_events.isClosed) {
      await _events.close();
    }
    if (!_status.isClosed) {
      await _status.close();
    }
  }

  /// The connection loop: one iteration per attempt, forever, until stop() or
  /// a rejected token. Never awaited by [start].
  Future<void> _run() async {
    bool reconnect = false;
    while (_running && !_stopped) {
      final String? token;
      try {
        token = await tokenReader();
      } on Object {
        // A keystore read failure is a transient availability problem: retry.
        if (_stopped) {
          return;
        }
        _emitStatus(LiveStatus.hubUnavailable);
        _backoff += 1;
        await _delay(_backoffDelay(_backoff));
        continue;
      }
      if (_stopped) {
        return;
      }
      if (token == null || token.isEmpty) {
        // No usable token is a re-auth state, not a crash loop.
        _emitStatus(LiveStatus.tokenRejected);
        _running = false;
        return;
      }

      final _AttemptResult result = await _attempt(token, reconnect: reconnect);
      if (_stopped) {
        return;
      }

      switch (result.kind) {
        case _AttemptKind.dropped:
          _emitStatus(LiveStatus.reconnecting);
          _backoff += 1;
          await _delay(_backoffDelay(_backoff));
          reconnect = true;
        case _AttemptKind.retry:
          _emitStatus(result.status ?? LiveStatus.hubUnavailable);
          _backoff += 1;
          await _delay(_backoffDelay(_backoff));
        case _AttemptKind.tokenRejected:
          _emitStatus(LiveStatus.tokenRejected);
          _running = false;
          return;
      }
    }
  }

  /// Opens, authenticates, subscribes, and serves events until the stream ends.
  Future<_AttemptResult> _attempt(String token, {required bool reconnect}) async {
    final WebSocketChannel? channel = await _openChannel();
    if (_stopped) {
      if (channel != null) {
        await _closeSink(channel);
        _closedChannels.remove(channel);
      }
      return const _AttemptResult(_AttemptKind.retry);
    }
    if (channel == null) {
      return _AttemptResult(_AttemptKind.retry, _openFailureStatus);
    }

    _activeChannel = channel;
    final StreamIterator<dynamic> messages =
        StreamIterator<dynamic>(channel.stream);
    _activeMessages = messages;
    try {
      // Step 3: the server must open the conversation with auth_required.
      final Object? first = await _readMessage(messages);
      if (identical(first, _noMessage) || !_isType(first, 'auth_required')) {
        return const _AttemptResult(_AttemptKind.retry);
      }

      // Step 4: authenticate. This is the ONLY place the token goes on the wire.
      channel.sink.add(
        jsonEncode(<String, String>{'type': 'auth', 'access_token': token}),
      );
      final Object? authReply = await _readMessage(messages);
      if (identical(authReply, _noMessage)) {
        return const _AttemptResult(_AttemptKind.retry);
      }
      if (_isType(authReply, 'auth_invalid')) {
        return const _AttemptResult(_AttemptKind.tokenRejected);
      }
      if (!_isType(authReply, 'auth_ok')) {
        return const _AttemptResult(_AttemptKind.retry);
      }

      // Step 5: subscribe to state_changed with an incrementing request id.
      final int id = _nextId++;
      channel.sink.add(jsonEncode(<String, Object>{
        'id': id,
        'type': 'subscribe_events',
        'event_type': 'state_changed',
      }));

      // Step 6: after a drop, re-read the tracked entities to close the gap.
      if (reconnect) {
        final bool rejected = await _rereadEntities();
        if (rejected) {
          return const _AttemptResult(_AttemptKind.tokenRejected);
        }
      }
      if (_stopped) {
        return const _AttemptResult(_AttemptKind.retry);
      }

      // Step 7: connected. Serve events until the stream ends or errors.
      _emitStatus(LiveStatus.connected);
      while (!_stopped) {
        final Object? message;
        try {
          if (!await messages.moveNext()) {
            return const _AttemptResult(_AttemptKind.dropped);
          }
          message = messages.current;
        } on Object {
          return const _AttemptResult(_AttemptKind.dropped);
        }
        _handleMessage(message);
      }
      return const _AttemptResult(_AttemptKind.dropped);
    } finally {
      _activeChannel = null;
      _activeMessages = null;
      await _cancelMessages(messages);
      await _closeSink(channel);
      // Drop the entry now the attempt is over, so only the stop()-in-flight
      // window is guarded and the set never grows across attempts. A racing
      // double close is harmless: WebSocketSink.close() is idempotent.
      _closedChannels.remove(channel);
    }
  }

  /// Re-reads the tracked entities and re-emits them as render-cache events.
  /// Returns true when the token was rejected, so the caller must stop.
  Future<bool> _rereadEntities() async {
    for (final String entityId in _tracked) {
      if (_stopped) {
        return false;
      }
      try {
        // fetchEntity is a render-cache refresh, never a decision input.
        final EntitySnapshot snapshot = await hubClient.fetchEntity(entityId);
        _emitEvent(EntityStateEvent(
          entityId: snapshot.entityId,
          state: snapshot.state,
          attributes: snapshot.attributes,
          lastUpdated: snapshot.lastUpdated,
        ));
      } on TokenRejectedException {
        return true;
      } on Object {
        // A transient per-entity failure is ignored; the next state_changed
        // or reconnect repopulates the row.
      }
    }
    return false;
  }

  /// Decodes one inbound frame and, when it is a `state_changed` event with a
  /// usable entity id and state, emits a render-cache update. Everything else
  /// (acks, pongs, malformed JSON, partial events) is ignored — never thrown.
  void _handleMessage(Object? raw) {
    if (raw is! String) {
      return;
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return;
    }
    if (decoded is! Map<String, dynamic> || decoded['type'] != 'event') {
      return;
    }
    final Object? event = decoded['event'];
    if (event is! Map || event['event_type'] != 'state_changed') {
      return;
    }
    final Object? data = event['data'];
    if (data is! Map) {
      return;
    }
    final Object? entityId = data['entity_id'];
    final Object? newState = data['new_state'];
    if (entityId is! String || newState is! Map) {
      return;
    }
    final Object? state = newState['state'];
    if (state is! String) {
      return;
    }
    final Map<String, dynamic> attributes =
        (newState['attributes'] as Map?)?.cast<String, dynamic>() ??
            const <String, dynamic>{};
    final DateTime? lastUpdated = _parseTimestamp(newState['last_updated']);

    // A live event proves the connection is working, so the backoff restarts
    // from the base after any outage (no thundering herd on recovery).
    _backoff = 0;
    _emitEvent(EntityStateEvent(
      entityId: entityId,
      state: state,
      attributes: attributes,
      lastUpdated: lastUpdated,
    ));
  }

  /// Opens the socket and waits for it to become ready, mapping every failure
  /// onto [_openFailureStatus]. Returns null when the attempt could not open.
  Future<WebSocketChannel?> _openChannel() async {
    final WebSocketChannel channel;
    try {
      channel = await _channelFactory(_webSocketUri).timeout(connectTimeout);
    } on WebSocketChannelException catch (e) {
      _openFailureStatus = _mapChannelException(e);
      return null;
    } on SocketException catch (e) {
      _openFailureStatus = _mapSocketException(e);
      return null;
    } on TimeoutException {
      _openFailureStatus = LiveStatus.hubUnavailable;
      return null;
    } on Object {
      _openFailureStatus = LiveStatus.hubUnavailable;
      return null;
    }

    // The factory produced a channel, so a socket now exists: it must be closed
    // on any failure below (e.g. the hub accepts TCP but never completes the
    // upgrade), or the attempt would leak it. It is not yet owned by an attempt,
    // so close it directly rather than through the guarded set.
    try {
      await channel.ready.timeout(connectTimeout);
      return channel;
    } on WebSocketChannelException catch (e) {
      _openFailureStatus = _mapChannelException(e);
    } on SocketException catch (e) {
      _openFailureStatus = _mapSocketException(e);
    } on TimeoutException {
      _openFailureStatus = LiveStatus.hubUnavailable;
    } on Object {
      _openFailureStatus = LiveStatus.hubUnavailable;
    }
    await _closeChannelQuietly(channel);
    return null;
  }

  /// Reads the next inbound message, or [_noMessage] on end, error, or timeout.
  Future<Object?> _readMessage(StreamIterator<dynamic> messages) async {
    try {
      if (!await messages.moveNext().timeout(connectTimeout)) {
        return _noMessage;
      }
      return messages.current;
    } on Object {
      return _noMessage;
    }
  }

  /// Closes [channel]'s sink once within the `stop()`/attempt-finally window.
  /// The owning attempt clears its entry when it finishes, so the set is bounded
  /// by the single in-flight attempt and a racing double close is harmless.
  Future<void> _closeSink(WebSocketChannel channel) async {
    if (!_closedChannels.add(channel)) {
      return;
    }
    await _closeChannelQuietly(channel);
  }

  /// Cancels [messages] with a bound, so a stream whose peer vanished can never
  /// stall the reconnect loop or `stop()`. The iterator is abandoned on timeout.
  Future<void> _cancelMessages(StreamIterator<dynamic> messages) async {
    try {
      await messages.cancel().timeout(_cleanupTimeout);
    } on Object {
      // The stream is abandoned either way.
    }
  }

  /// Closes a socket that is not owned by an attempt (e.g. one that never became
  /// ready), ignoring any error from an already-broken socket. The await is
  /// bounded so a peer that never answers the close handshake cannot stall the
  /// caller.
  Future<void> _closeChannelQuietly(WebSocketChannel channel) async {
    try {
      await channel.sink.close().timeout(_cleanupTimeout);
    } on Object {
      // A socket that is already gone needs no further action here.
    }
  }

  void _emitStatus(LiveStatus status) {
    if (_stopped || _status.isClosed) {
      return;
    }
    _status.add(status);
  }

  void _emitEvent(EntityStateEvent event) {
    if (_stopped || _events.isClosed) {
      return;
    }
    _events.add(event);
  }

  /// Exponential backoff: base 1s, factor 2, cap 30s, with ±20% jitter.
  ///
  /// The exponent is clamped before the shift: `1 << 6` (1s · 2^6 = 64s) already
  /// exceeds the cap, and growing it further would overflow the int and defeat
  /// the cap during a long outage (negative or zero delays → a hot retry loop).
  Duration _backoffDelay(int attempt) {
    final int exponent = math.min(attempt - 1, 6);
    final int rawMs = _baseBackoffMs * (1 << exponent);
    final int cappedMs = math.min(_maxBackoffMs, rawMs);
    final double factor = 0.8 + 0.4 * _jitter();
    return Duration(milliseconds: (cappedMs * factor).round());
  }

  /// `http(s)://host:8123` becomes `ws(s)://host:8123/api/websocket`.
  ///
  /// The address is read ONCE per derivation, so one connection attempt can
  /// never straddle two hubs.
  Uri get _webSocketUri {
    final Uri base = Uri.parse(baseUrlReader());
    final bool secure = base.scheme == 'https' || base.scheme == 'wss';
    return base.replace(scheme: secure ? 'wss' : 'ws', path: '/api/websocket');
  }

  static bool _isType(Object? message, String type) {
    if (message is! String) {
      return false;
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(message);
    } on FormatException {
      return false;
    }
    return decoded is Map && decoded['type'] == type;
  }

  static DateTime? _parseTimestamp(Object? value) {
    if (value is! String) {
      return null;
    }
    return DateTime.tryParse(value)?.toUtc();
  }

  static LiveStatus _mapChannelException(WebSocketChannelException e) {
    final Object? inner = e.inner;
    if (inner is SocketException) {
      return _mapSocketException(inner);
    }
    return LiveStatus.hubUnavailable;
  }

  /// Design-doc rule: only a no-route errno means `offline`; a refused
  /// connection or DNS failure means the network is up and the hub is not.
  static LiveStatus _mapSocketException(SocketException e) {
    final int? errno = e.osError?.errorCode;
    if (errno != null && noDeviceRouteErrnos.contains(errno)) {
      return LiveStatus.offline;
    }
    return LiveStatus.hubUnavailable;
  }
}
