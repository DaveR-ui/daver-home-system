import 'dart:async';
import 'dart:convert';
import 'dart:io';

// stream_channel is transitive (via web_socket_channel); the mixin is needed to
// implement the WebSocketChannel interface in a fake.
// ignore: depend_on_referenced_packages
import 'package:stream_channel/stream_channel.dart';
import 'package:daver_home/hub/hub_client.dart';
import 'package:daver_home/hub/live_state_client.dart';
import 'package:daver_home/hub/ws_live_state_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// An in-memory [WebSocketChannel]. Inbound frames are pushed with [push]; the
/// frames the client sends are recorded in [sent]. When [autoHandshake] is set
/// it answers `auth` and `subscribe_events` like Home Assistant would.
class _FakeChannel extends StreamChannelMixin implements WebSocketChannel {
  _FakeChannel({this.authReply = 'auth_ok', this.hangOnClose = false});

  final StreamController<Object?> _incoming = StreamController<Object?>();
  final List<Object?> sent = <Object?>[];
  final String authReply;

  /// Models a dead peer: when true, [sink.close] never completes.
  final bool hangOnClose;

  bool sinkClosed = false;

  late final _FakeSink _sink = _FakeSink(this);

  @override
  Stream<Object?> get stream => _incoming.stream;

  @override
  WebSocketSink get sink => _sink;

  @override
  int? get closeCode => null;

  @override
  String? get closeReason => null;

  @override
  String? get protocol => null;

  @override
  Future<void> get ready => Future<void>.value();

  void push(Object? message) {
    if (!_incoming.isClosed) {
      _incoming.add(message);
    }
  }

  Future<void> closeFromServer() => _incoming.close();

  void _recordSent(Object? data) {
    sent.add(data);
    final Object? decoded = _tryDecode(data);
    if (decoded is! Map) {
      return;
    }
    if (decoded['type'] == 'auth') {
      scheduleMicrotask(
        () => push(jsonEncode(<String, Object>{'type': authReply})),
      );
    } else if (decoded['type'] == 'subscribe_events') {
      scheduleMicrotask(
        () => push(
          jsonEncode(<String, Object>{
            'id': decoded['id'] as int,
            'type': 'result',
            'success': true,
          }),
        ),
      );
    }
  }
}

class _FakeSink implements WebSocketSink {
  _FakeSink(this._channel);

  final _FakeChannel _channel;
  final Completer<void> _done = Completer<void>();

  @override
  void add(dynamic data) => _channel._recordSent(data);

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<void> addStream(Stream<dynamic> stream) async {
    await stream.forEach(add);
  }

  @override
  Future<void> close([int? closeCode, String? closeReason]) async {
    _channel.sinkClosed = true;
    if (_channel.hangOnClose) {
      // A peer that vanished mid-stream never answers the close handshake.
      await Completer<void>().future;
      return;
    }
    if (!_done.isCompleted) {
      _done.complete();
    }
  }

  @override
  Future<void> get done => _done.future;
}

/// Scripted hub for the reconnect re-read: returns the configured snapshots.
class _FakeHubClient implements HubClient {
  final List<String> fetched = <String>[];
  final Map<String, EntitySnapshot> byId = <String, EntitySnapshot>{};

  /// Optional per-entity failure, evaluated before [byId].
  Exception? Function(String entityId)? fetchError;

  @override
  Future<bool> probeHub() async => true;

  @override
  Future<List<EntitySnapshot>> fetchStates() async => byId.values.toList();

  @override
  Future<EntitySnapshot> fetchEntity(String entityId) async {
    fetched.add(entityId);
    final Exception? error = fetchError?.call(entityId);
    if (error != null) {
      throw error;
    }
    final EntitySnapshot? snapshot = byId[entityId];
    if (snapshot == null) {
      throw const HubUnavailableException();
    }
    return snapshot;
  }
}

Object? _tryDecode(Object? data) {
  if (data is! String) {
    return null;
  }
  try {
    return jsonDecode(data);
  } on FormatException {
    return null;
  }
}

void main() {
  late _FakeHubClient hub;
  late List<Duration> delays;
  late List<_FakeChannel> channels;
  late List<LiveStatus> statuses;
  late List<EntityStateEvent> events;
  String? token;

  /// Opens an auto-handshaking channel and pushes `auth_required` on it.
  Future<WebSocketChannel> defaultFactory(Uri uri) async {
    final _FakeChannel channel = _FakeChannel();
    channels.add(channel);
    scheduleMicrotask(
      () => channel.push(jsonEncode(<String, Object>{'type': 'auth_required'})),
    );
    return channel;
  }

  WsLiveStateClient build({
    Future<WebSocketChannel> Function(Uri)? factory,
    Duration connectTimeout = const Duration(seconds: 10),
  }) {
    return WsLiveStateClient(
      baseUrlReader: () => 'http://hub.test:8123',
      tokenReader: () async => token,
      hubClient: hub,
      channelFactory: factory ?? defaultFactory,
      delay: (Duration duration) async => delays.add(duration),
      jitter: () => 0.5,
      connectTimeout: connectTimeout,
    );
  }

  setUp(() {
    hub = _FakeHubClient();
    delays = <Duration>[];
    channels = <_FakeChannel>[];
    statuses = <LiveStatus>[];
    events = <EntityStateEvent>[];
    token = 'tok';
  });

  test(
    'handshake sends auth then subscribe, and the id counter increments',
    () async {
      final WsLiveStateClient client = build();
      client.status.listen(statuses.add);

      await client.start();
      await pumpEventQueue();

      expect(channels, hasLength(1));
      final List<Object?> firstSent = channels.first.sent;
      expect(firstSent, hasLength(2));
      expect(_tryDecode(firstSent[0]), <String, Object?>{
        'type': 'auth',
        'access_token': 'tok',
      });
      expect(_tryDecode(firstSent[1]), <String, Object?>{
        'id': 1,
        'type': 'subscribe_events',
        'event_type': 'state_changed',
      });
      expect(statuses, contains(LiveStatus.connected));

      // Drop the socket and let the client reconnect: the next subscribe id is 2.
      await channels.first.closeFromServer();
      await pumpEventQueue();

      expect(channels, hasLength(2));
      expect(_tryDecode(channels[1].sent[1]), <String, Object?>{
        'id': 2,
        'type': 'subscribe_events',
        'event_type': 'state_changed',
      });

      await client.stop();
    },
  );

  test(
    'the WebSocket URI follows the current address on every attempt',
    () async {
      String baseUrl = 'http://old.test:8123';
      final List<Uri> attempted = <Uri>[];

      Future<WebSocketChannel> factory(Uri uri) async {
        attempted.add(uri);
        final _FakeChannel channel = _FakeChannel();
        channels.add(channel);
        scheduleMicrotask(
          () => channel.push(
            jsonEncode(<String, Object>{'type': 'auth_required'}),
          ),
        );
        return channel;
      }

      final WsLiveStateClient client = WsLiveStateClient(
        baseUrlReader: () => baseUrl,
        tokenReader: () async => 'tok',
        hubClient: hub,
        channelFactory: factory,
        delay: (Duration duration) async => delays.add(duration),
        jitter: () => 0.5,
      );

      await client.start();
      await pumpEventQueue();
      expect(attempted, <Uri>[Uri.parse('ws://old.test:8123/api/websocket')]);

      // The address moves while the socket is live; the next connection attempt
      // must derive its URI from the new address.
      baseUrl = 'http://new.test:8123';
      await channels.first.closeFromServer();
      await pumpEventQueue(times: 200);

      expect(attempted, <Uri>[
        Uri.parse('ws://old.test:8123/api/websocket'),
        Uri.parse('ws://new.test:8123/api/websocket'),
      ]);
      expect(channels, hasLength(2));

      await client.stop();
    },
  );

  test('a state_changed event becomes one render-cache event', () async {
    final WsLiveStateClient client = build();
    client.events.listen(events.add);

    await client.start();
    await pumpEventQueue();

    channels.first.push(
      jsonEncode(<String, Object?>{
        'type': 'event',
        'event': <String, Object?>{
          'event_type': 'state_changed',
          'data': <String, Object?>{
            'entity_id': 'light.kitchen',
            'new_state': <String, Object?>{
              'state': 'on',
              'attributes': <String, Object?>{'brightness': 180},
              'last_updated': '2026-10-14T10:00:00+00:00',
            },
          },
        },
      }),
    );
    await pumpEventQueue();

    expect(events, hasLength(1));
    expect(events.single.entityId, 'light.kitchen');
    expect(events.single.state, 'on');
    expect(events.single.attributes, <String, dynamic>{'brightness': 180});
    expect(events.single.lastUpdated, DateTime.utc(2026, 10, 14, 10));

    await client.stop();
  });

  test(
    'acks, pongs, malformed frames, and partial events are ignored',
    () async {
      final WsLiveStateClient client = build();
      client.events.listen(events.add);

      await client.start();
      await pumpEventQueue();

      channels.first
        ..push(
          jsonEncode(<String, Object>{
            'id': 7,
            'type': 'result',
            'success': true,
          }),
        )
        ..push(jsonEncode(<String, Object>{'type': 'pong', 'id': 7}))
        ..push('{ not json')
        ..push(
          jsonEncode(<String, Object?>{
            'type': 'event',
            'event': <String, Object?>{
              'event_type': 'state_changed',
              'data': <String, Object?>{
                'new_state': <String, Object?>{'state': 'on'},
              },
            },
          }),
        )
        ..push(
          jsonEncode(<String, Object?>{
            'type': 'event',
            'event': <String, Object?>{
              'event_type': 'state_changed',
              'data': <String, Object?>{
                'entity_id': 'light.kitchen',
                'new_state': <String, Object?>{
                  'attributes': <String, Object?>{},
                },
              },
            },
          }),
        );
      await pumpEventQueue();

      expect(events, isEmpty);

      // The loop is still alive: a valid event still arrives afterwards.
      channels.first.push(
        jsonEncode(<String, Object?>{
          'type': 'event',
          'event': <String, Object?>{
            'event_type': 'state_changed',
            'data': <String, Object?>{
              'entity_id': 'light.kitchen',
              'new_state': <String, Object?>{'state': 'on'},
            },
          },
        }),
      );
      await pumpEventQueue();

      expect(events, hasLength(1));

      await client.stop();
    },
  );

  test(
    'a drop reconnects with capped backoff and re-reads tracked entities',
    () async {
      hub.byId['light.a'] = EntitySnapshot(
        entityId: 'light.a',
        state: 'on',
        attributes: const <String, dynamic>{},
        lastUpdated: DateTime.utc(2026, 1, 1),
      );
      hub.byId['light.b'] = const EntitySnapshot(
        entityId: 'light.b',
        state: 'off',
        attributes: <String, dynamic>{},
      );

      final WsLiveStateClient client = build();
      client.setTrackedEntities(<String>['light.a', 'light.b']);
      client.events.listen(events.add);
      // Close every freshly connected channel to force the backoff sequence.
      client.status.listen((LiveStatus status) {
        if (status == LiveStatus.connected && delays.length < 7) {
          final _FakeChannel current = channels.last;
          scheduleMicrotask(current.closeFromServer);
        }
      });

      await client.start();
      await pumpEventQueue(times: 500);

      expect(delays, <Duration>[
        const Duration(seconds: 1),
        const Duration(seconds: 2),
        const Duration(seconds: 4),
        const Duration(seconds: 8),
        const Duration(seconds: 16),
        const Duration(seconds: 30),
        const Duration(seconds: 30),
      ]);
      // No thundering herd: the delay never decreases and never exceeds the cap.
      for (int i = 1; i < delays.length; i++) {
        expect(delays[i] >= delays[i - 1], isTrue);
        expect(delays[i] <= const Duration(seconds: 30), isTrue);
      }
      // Every reconnection re-authenticated, re-subscribed, and re-read the two
      // tracked entities, re-emitting them as events.
      expect(channels.length, 8);
      for (final _FakeChannel channel in channels.skip(1)) {
        expect(channel.sent, hasLength(2));
        expect(_tryDecode(channel.sent[0]), <String, Object?>{
          'type': 'auth',
          'access_token': 'tok',
        });
      }
      expect(hub.fetched, containsAllInOrder(<String>['light.a', 'light.b']));
      expect(
        events.where((EntityStateEvent e) => e.entityId == 'light.a'),
        isNotEmpty,
      );

      await client.stop();
    },
  );

  test('a close that never completes does not stall the reconnect loop', () async {
    hub.byId['light.a'] = const EntitySnapshot(
      entityId: 'light.a',
      state: 'on',
      attributes: <String, dynamic>{},
    );

    Future<WebSocketChannel> factory(Uri uri) async {
      // The first socket models a hub killed mid-stream: its close handshake
      // never completes. Every later socket is healthy.
      final _FakeChannel channel = _FakeChannel(hangOnClose: channels.isEmpty);
      channels.add(channel);
      scheduleMicrotask(
        () =>
            channel.push(jsonEncode(<String, Object>{'type': 'auth_required'})),
      );
      return channel;
    }

    final WsLiveStateClient client = build(
      factory: factory,
      // Keep the bounded cleanup short so the test does not wait on the real
      // production bound.
      connectTimeout: const Duration(milliseconds: 50),
    );
    client.setTrackedEntities(<String>['light.a']);
    client.events.listen(events.add);
    client.status.listen(statuses.add);

    await client.start();
    await pumpEventQueue();
    expect(channels, hasLength(1));
    expect(statuses.last, LiveStatus.connected);

    // The hub dies. The inbound stream ends, but the fake sink's close() never
    // completes, exactly like a close handshake to a vanished peer. The attempt
    // must bound that cleanup and let the reconnect loop run again.
    await channels.first.closeFromServer();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await pumpEventQueue(times: 200);

    expect(statuses, contains(LiveStatus.reconnecting));
    expect(channels, hasLength(2));
    expect(hub.fetched, <String>['light.a']);
    expect(
      events.where((EntityStateEvent e) => e.entityId == 'light.a'),
      isNotEmpty,
    );
    expect(statuses.last, LiveStatus.connected);

    await client.stop();
  });

  test('auth_invalid is a re-auth state, not a crash loop', () async {
    Future<WebSocketChannel> factory(Uri uri) async {
      final _FakeChannel channel = _FakeChannel(authReply: 'auth_invalid');
      channels.add(channel);
      scheduleMicrotask(
        () =>
            channel.push(jsonEncode(<String, Object>{'type': 'auth_required'})),
      );
      return channel;
    }

    final WsLiveStateClient client = build(factory: factory);
    client.status.listen(statuses.add);

    await client.start();
    await pumpEventQueue(times: 100);

    expect(statuses.last, LiveStatus.tokenRejected);
    expect(channels, hasLength(1));
    expect(channels.first.sinkClosed, isTrue);
    expect(delays, isEmpty);

    // No further connection attempts are made.
    await pumpEventQueue(times: 100);
    expect(channels, hasLength(1));

    await client.stop();
  });

  test('a no-route connect failure is offline and keeps retrying', () async {
    int calls = 0;
    Future<WebSocketChannel> factory(Uri uri) async {
      calls++;
      if (calls <= 2) {
        throw WebSocketChannelException.from(
          const SocketException(
            'Network is unreachable',
            osError: OSError('Network is unreachable', 101),
          ),
        );
      }
      return defaultFactory(uri);
    }

    final WsLiveStateClient client = build(factory: factory);
    client.status.listen(statuses.add);

    await client.start();
    await pumpEventQueue(times: 200);

    expect(statuses.first, LiveStatus.connecting);
    expect(statuses, contains(LiveStatus.offline));
    expect(statuses[1], LiveStatus.offline);
    expect(delays, <Duration>[
      const Duration(seconds: 1),
      const Duration(seconds: 2),
    ]);
    expect(statuses.last, LiveStatus.connected);

    await client.stop();
  });

  test(
    'a generic connect failure is hubUnavailable and keeps retrying',
    () async {
      int calls = 0;
      Future<WebSocketChannel> factory(Uri uri) async {
        calls++;
        if (calls <= 2) {
          throw WebSocketChannelException('connection refused');
        }
        return defaultFactory(uri);
      }

      final WsLiveStateClient client = build(factory: factory);
      client.status.listen(statuses.add);

      await client.start();
      await pumpEventQueue(times: 200);

      expect(statuses.first, LiveStatus.connecting);
      expect(statuses, contains(LiveStatus.hubUnavailable));
      expect(statuses[1], LiveStatus.hubUnavailable);
      expect(delays, <Duration>[
        const Duration(seconds: 1),
        const Duration(seconds: 2),
      ]);
      expect(statuses.last, LiveStatus.connected);

      await client.stop();
    },
  );

  test(
    'stop closes the channel and the streams, with no later emissions',
    () async {
      final WsLiveStateClient client = build();
      final Completer<void> eventsDone = Completer<void>();
      final Completer<void> statusDone = Completer<void>();
      client.events.listen(events.add, onDone: eventsDone.complete);
      client.status.listen(statuses.add, onDone: statusDone.complete);

      await client.start();
      await pumpEventQueue();
      await client.stop();

      expect(channels.single.sinkClosed, isTrue);
      await statusDone.future;
      await eventsDone.future;

      final int statusesAfterStop = statuses.length;
      channels.single.push(
        jsonEncode(<String, Object?>{
          'type': 'event',
          'event': <String, Object?>{
            'event_type': 'state_changed',
            'data': <String, Object?>{
              'entity_id': 'light.kitchen',
              'new_state': <String, Object?>{'state': 'on'},
            },
          },
        }),
      );
      await pumpEventQueue();

      expect(statuses, hasLength(statusesAfterStop));
      expect(events, isEmpty);
    },
  );

  test('an empty or null token is a re-auth state with no attempts', () async {
    for (final String? value in <String?>[null, '']) {
      hub = _FakeHubClient();
      delays = <Duration>[];
      channels = <_FakeChannel>[];
      statuses = <LiveStatus>[];
      token = value;

      final WsLiveStateClient client = build();
      client.status.listen(statuses.add);

      await client.start();
      await pumpEventQueue(times: 100);

      expect(statuses.last, LiveStatus.tokenRejected);
      expect(channels, isEmpty);
      expect(delays, isEmpty);

      await client.stop();
    }
  });

  test('a re-read that rejects the token stops at tokenRejected', () async {
    hub.fetchError = (String entityId) => const TokenRejectedException();

    final WsLiveStateClient client = build();
    client.setTrackedEntities(<String>['light.a']);
    client.status.listen(statuses.add);

    await client.start();
    await pumpEventQueue();
    expect(channels, hasLength(1));

    // Drop, then the post-reconnect re-read rejects the stored token.
    await channels.first.closeFromServer();
    await pumpEventQueue(times: 200);

    expect(statuses.last, LiveStatus.tokenRejected);
    expect(channels, hasLength(2));
    expect(channels.last.sinkClosed, isTrue);

    // The loop stopped: no further connection attempts are made.
    await pumpEventQueue(times: 200);
    expect(channels, hasLength(2));

    await client.stop();
  });

  test(
    'a per-entity re-read failure is ignored and retried on the next drop',
    () async {
      hub.byId['light.a'] = const EntitySnapshot(
        entityId: 'light.a',
        state: 'on',
        attributes: <String, dynamic>{},
      );
      hub.fetchError = (String entityId) =>
          entityId == 'light.b' ? const HubUnavailableException() : null;

      final WsLiveStateClient client = build();
      client.setTrackedEntities(<String>['light.a', 'light.b']);
      client.events.listen(events.add);
      client.status.listen(statuses.add);

      await client.start();
      await pumpEventQueue();
      await channels.first.closeFromServer();
      await pumpEventQueue(times: 200);

      // The healthy entity was re-emitted; the failing one did not break the loop.
      expect(
        events.map((EntityStateEvent e) => e.entityId),
        contains('light.a'),
      );
      expect(
        events.any((EntityStateEvent e) => e.entityId == 'light.b'),
        isFalse,
      );
      expect(statuses.last, LiveStatus.connected);
      expect(channels, hasLength(2));
      expect(hub.fetched, <String>['light.a', 'light.b']);

      // A later drop re-reads both entities again.
      await channels.last.closeFromServer();
      await pumpEventQueue(times: 200);

      expect(channels, hasLength(3));
      expect(hub.fetched, <String>['light.a', 'light.b', 'light.a', 'light.b']);

      await client.stop();
    },
  );

  test('an inbound state_changed resets the accumulated backoff', () async {
    final WsLiveStateClient client = build();
    client.status.listen(statuses.add);

    await client.start();
    await pumpEventQueue();

    // A first drop with no event: the backoff starts at the base.
    await channels.first.closeFromServer();
    await pumpEventQueue(times: 200);
    expect(delays, <Duration>[const Duration(seconds: 1)]);

    // Reconnect and prove the connection is live with one event.
    channels.last.push(
      jsonEncode(<String, Object?>{
        'type': 'event',
        'event': <String, Object?>{
          'event_type': 'state_changed',
          'data': <String, Object?>{
            'entity_id': 'light.a',
            'new_state': <String, Object?>{'state': 'on'},
          },
        },
      }),
    );
    await pumpEventQueue();

    // The next drop restarts from the base, not the accumulated 2s.
    await channels.last.closeFromServer();
    await pumpEventQueue(times: 200);
    expect(delays, <Duration>[
      const Duration(seconds: 1),
      const Duration(seconds: 1),
    ]);

    await client.stop();
  });

  test('the backoff never overflows or spins across a long outage', () async {
    final List<Duration> recorded = <Duration>[];
    int calls = 0;
    late final WsLiveStateClient client;

    Future<WebSocketChannel> alwaysFails(Uri uri) async {
      calls++;
      throw WebSocketChannelException('down');
    }

    client = WsLiveStateClient(
      baseUrlReader: () => 'http://hub.test:8123',
      tokenReader: () async => 'tok',
      hubClient: hub,
      channelFactory: alwaysFails,
      delay: (Duration duration) async {
        recorded.add(duration);
        if (recorded.length >= 70) {
          await client.stop();
        }
      },
      jitter: () => 0.5,
    );

    await client.start();
    await pumpEventQueue(times: 2000);

    // 70 attempts: the exponent would have wrapped long before this.
    expect(recorded, hasLength(70));
    expect(calls, 70);
    for (final Duration delay in recorded) {
      // Never negative or zero (a hot retry loop), never above the cap + jitter.
      expect(delay.inMilliseconds, greaterThan(0));
      expect(delay.inMilliseconds, greaterThanOrEqualTo(800));
      expect(delay.inMilliseconds, lessThanOrEqualTo(36000));
    }
    // The cap holds and the sequence is 1s,2s,4s,8s,16s,30s,30s,...
    expect(recorded.take(7).toList(), <Duration>[
      const Duration(seconds: 1),
      const Duration(seconds: 2),
      const Duration(seconds: 4),
      const Duration(seconds: 8),
      const Duration(seconds: 16),
      const Duration(seconds: 30),
      const Duration(seconds: 30),
    ]);
    expect(recorded.last, const Duration(seconds: 30));
  });
}
