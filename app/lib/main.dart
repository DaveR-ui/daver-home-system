import 'dart:async';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'hub/hub_client.dart';
import 'hub/hub_status_controller.dart';
import 'hub/http_hub_client.dart';
import 'hub/live_state_client.dart';
import 'hub/secure_token_store.dart';
import 'hub/token_store.dart';
import 'hub/ws_live_state_client.dart';
import 'hub_status.dart';
import 'ui/hub_banner.dart';
import 'ui/token_entry.dart';

void main() => runApp(const DaverApp());

/// The root of the daver-home phone app.
///
/// [hubClient], [tokenStore], and [liveStateClient] are test seams; when null
/// the production HTTP/WebSocket clients and the OS keystore are used.
class DaverApp extends StatelessWidget {
  const DaverApp({super.key, this.hubClient, this.tokenStore, this.liveStateClient});

  final HubClient? hubClient;
  final TokenStore? tokenStore;

  /// Test seam. Inject [hubClient] and [liveStateClient] together in tests:
  /// injecting only the live seam falls back to the production REST client and
  /// the OS keystore.
  final LiveStateClient? liveStateClient;

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
      ),
      debugShowCheckedModeBanner: false,
    );
  }
}

/// The first screen: a stand-in for the rooms/devices list.
class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    this.hubClient,
    this.tokenStore,
    this.liveStateClient,
  });

  final HubClient? hubClient;
  final TokenStore? tokenStore;

  /// Test seam. Inject [hubClient] and [liveStateClient] together in tests:
  /// injecting only the live seam falls back to the production REST client and
  /// the OS keystore.
  final LiveStateClient? liveStateClient;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late final HubStatusController _controller;

  /// Only set when this screen created the HTTP client, so it closes it.
  http.Client? _ownedHttpClient;

  /// Only set when this screen created the WebSocket client, so it stops it.
  LiveStateClient? _ownedLiveState;

  @override
  void initState() {
    super.initState();
    final TokenStore tokens = widget.tokenStore ?? SecureTokenStore();
    final HubClient client = widget.hubClient ?? _productionClient(tokens);
    // With an injected hub client but no live client, pass no live state so the
    // increment-1 test widgets keep their REST-only behaviour.
    final LiveStateClient? live = widget.liveStateClient ??
        (widget.hubClient == null ? _productionLiveState(tokens, client) : null);
    _controller = HubStatusController(
      client: client,
      tokens: tokens,
      liveState: live,
    );
    _controller.connect();
  }

  HubClient _productionClient(TokenStore tokens) {
    final http.Client httpClient = http.Client();
    _ownedHttpClient = httpClient;
    return HttpHubClient(
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
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text(
                'Daver Home',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 8),
              Text(
                'Your Home Assistant control surface for this home. '
                'Home Assistant keeps the state; this app only shows it.',
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
                        if (status != null) const SizedBox(height: 12),
                        TokenEntryField(
                          onSubmit: (String token) {
                            // Fire-and-forget: saveToken never throws, and the
                            // banner and field re-render through the controller.
                            unawaited(_controller.saveToken(token));
                          },
                        ),
                      ],
                    ],
                  );
                },
              ),
              const SizedBox(height: 24),
              Text(
                'Rooms and devices will appear here once the hub client lands.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
