import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'hub/hub_client.dart';
import 'hub/hub_status_controller.dart';
import 'hub/http_hub_client.dart';
import 'hub/http_light_command_client.dart';
import 'hub/light_command_client.dart';
import 'hub/live_state_client.dart';
import 'hub/secure_token_store.dart';
import 'hub/token_store.dart';
import 'hub/ws_live_state_client.dart';
import 'hub_status.dart';
import 'ui/hub_banner.dart';
import 'ui/rooms_devices_screen.dart';
import 'ui/token_entry.dart';

void main() => runApp(const DaverApp());

/// The root of the daver-home phone app.
///
/// [hubClient], [tokenStore], [liveStateClient], and [commandClient] are test
/// seams; when null the production HTTP/WebSocket clients and the OS keystore
/// are used.
class DaverApp extends StatelessWidget {
  const DaverApp({
    super.key,
    this.hubClient,
    this.tokenStore,
    this.liveStateClient,
    this.commandClient,
  });

  final HubClient? hubClient;
  final TokenStore? tokenStore;

  /// Test seam. Inject [hubClient] and [liveStateClient] together in tests:
  /// injecting only the live seam falls back to the production REST client and
  /// the OS keystore.
  final LiveStateClient? liveStateClient;

  /// Test seam for the light-command write path. When null, the production
  /// command client is built only alongside the production REST client;
  /// injecting a fake [hubClient] without this leaves command null (REST-only).
  final LightCommandClient? commandClient;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Daver Home',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      home: HomeScreen(
        hubClient: hubClient,
        tokenStore: tokenStore,
        liveStateClient: liveStateClient,
        commandClient: commandClient,
      ),
      debugShowCheckedModeBanner: false,
    );
  }
}

/// The first screen: the banner, token entry, and the rooms/devices list.
class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    this.hubClient,
    this.tokenStore,
    this.liveStateClient,
    this.commandClient,
  });

  final HubClient? hubClient;
  final TokenStore? tokenStore;

  /// Test seam. Inject [hubClient] and [liveStateClient] together in tests:
  /// injecting only the live seam falls back to the production REST client and
  /// the OS keystore.
  final LiveStateClient? liveStateClient;

  /// Test seam for the light-command write path; see [DaverApp.commandClient].
  final LightCommandClient? commandClient;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  /// The vertical gap between the scrollable header and the list below it.
  static const double _listGap = 8;

  late final HubStatusController _controller;

  /// Only set when this screen created the HTTP client, so it closes it.
  http.Client? _ownedHttpClient;

  /// Only set when this screen created the WebSocket client, so it stops it.
  LiveStateClient? _ownedLiveState;

  @override
  void initState() {
    super.initState();
    final TokenStore tokens = widget.tokenStore ?? SecureTokenStore();

    // In production a single http.Client is shared by the REST probe and the
    // light-command write path, so the app owns one connection pool.
    final HubClient client;
    final LightCommandClient? command;
    if (widget.hubClient != null) {
      client = widget.hubClient!;
      command = widget.commandClient;
    } else {
      final http.Client httpClient = http.Client();
      _ownedHttpClient = httpClient;
      client = HttpHubClient(
        client: httpClient,
        tokenReader: tokens.readToken,
      );
      command = widget.commandClient ?? _productionCommand(tokens, httpClient);
    }

    // With an injected hub client but no live client, pass no live state so the
    // increment-1 test widgets keep their REST-only behaviour.
    final LiveStateClient? live = widget.liveStateClient ??
        (widget.hubClient == null ? _productionLiveState(tokens, client) : null);
    _controller = HubStatusController(
      client: client,
      tokens: tokens,
      liveState: live,
      command: command,
    );
    _controller.connect();
  }

  LightCommandClient _productionCommand(TokenStore tokens, http.Client httpClient) {
    return HttpLightCommandClient(
      client: httpClient,
      tokenReader: tokens.readToken,
    );
  }

  LiveStateClient _productionLiveState(TokenStore tokens, HubClient client) {
    final WsLiveStateClient live = WsLiveStateClient(
      baseUrl: defaultHubBaseUrl,
      tokenReader: tokens.readToken,
      hubClient: client,
    );
    _ownedLiveState = live;
    return live;
  }

  @override
  void dispose() {
    _controller.dispose();
    unawaited(_ownedLiveState?.stop());
    _ownedHttpClient?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Daver Home')),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            // The header keeps its natural height while it fits, so the list
            // below fills the rest exactly as before. When the viewport is too
            // short (keyboard open) the header is capped to the space left
            // after the list's gap and scrolls, so the fixed column never
            // overflows.
            final double headerMax =
                math.max(0.0, constraints.maxHeight - _listGap);
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: headerMax),
                  child: SingleChildScrollView(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          Text(
                            'Daver Home',
                            style: Theme.of(context).textTheme.headlineSmall,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Your Home Assistant control surface for this home. '
                            'Home Assistant keeps the state; this app only '
                            'shows it.',
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                          const SizedBox(height: 16),
                          AnimatedBuilder(
                            animation: _controller,
                            builder: (BuildContext context, Widget? child) {
                              final HubStatus? status = _controller.status;
                              return Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                mainAxisSize: MainAxisSize.min,
                                children: <Widget>[
                                  if (status != null) HubBanner(status: status),
                                  if (_controller.needsToken) ...<Widget>[
                                    if (status != null)
                                      const SizedBox(height: 12),
                                    TokenEntryField(
                                      onSubmit: (String token) {
                                        // Fire-and-forget: saveToken never
                                        // throws, and the banner and field
                                        // re-render through the controller.
                                        unawaited(
                                            _controller.saveToken(token));
                                      },
                                    ),
                                  ],
                                ],
                              );
                            },
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                // Flexible so the gap yields to zero instead of overflowing
                // the column on a viewport shorter than the gap itself.
                Flexible(child: SizedBox(height: _listGap)),
                Expanded(child: RoomsDevicesScreen(controller: _controller)),
              ],
            );
          },
        ),
      ),
    );
  }
}
