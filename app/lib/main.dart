import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'hub/hub_address.dart';
import 'hub/hub_client.dart';
import 'hub/hub_discovery.dart';
import 'hub/hub_discovery_nsd.dart';
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
/// [hubClient], [tokenStore], [liveStateClient], [commandClient], [discovery],
/// and [hubAddress] are test seams; when null the production HTTP/WebSocket
/// clients, the platform mDNS search, and the OS keystore are used.
class DaverApp extends StatelessWidget {
  const DaverApp({
    super.key,
    this.hubClient,
    this.tokenStore,
    this.liveStateClient,
    this.commandClient,
    this.discovery,
    this.hubAddress,
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

  /// Test seam for the mDNS search. When null the production [NsdHubDiscovery]
  /// is built only alongside the production clients, so a widget test never
  /// constructs the platform plugin.
  final HubDiscovery? discovery;

  /// Test seam for the address shared by every hub client.
  final HubAddress? hubAddress;

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
        discovery: discovery,
        hubAddress: hubAddress,
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
    this.discovery,
    this.hubAddress,
  });

  final HubClient? hubClient;
  final TokenStore? tokenStore;

  /// Test seam. Inject [hubClient] and [liveStateClient] together in tests:
  /// injecting only the live seam falls back to the production REST client and
  /// the OS keystore.
  final LiveStateClient? liveStateClient;

  /// Test seam for the light-command write path; see [DaverApp.commandClient].
  final LightCommandClient? commandClient;

  /// Test seam for the mDNS search; see [DaverApp.discovery].
  final HubDiscovery? discovery;

  /// Test seam for the shared hub address; see [DaverApp.hubAddress].
  final HubAddress? hubAddress;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  /// The vertical gap between the scrollable header and the list below it.
  static const double _listGap = 8;

  late final HubStatusController _controller;

  /// Only set when this screen created the HTTP client, so it closes it.
  http.Client? _ownedHttpClient;

  /// Only set when this screen created the WebSocket client, so it stops it.
  LiveStateClient? _ownedLiveState;

  /// Only set when this screen created the mDNS search, so it stops it. The
  /// platform search holds a Wi-Fi multicast lock while it runs, so it must be
  /// released when the screen goes away.
  HubDiscovery? _ownedDiscovery;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final TokenStore tokens = widget.tokenStore ?? SecureTokenStore();

    // The address is mutable and shared: mDNS can answer after the clients are
    // built, so every hub client reads it at use time instead of caching it.
    final HubAddress address = widget.hubAddress ??
        HubAddress(usableHubBaseUrl(defaultHubBaseUrl));

    // The production search is built only when this screen builds the clients;
    // a fake hub client must never construct the platform plugin, exactly like
    // the live client below.
    final HubDiscovery? discovery =
        widget.discovery ??
        (widget.hubClient == null ? NsdHubDiscovery() : null);
    if (widget.discovery == null && discovery != null) {
      _ownedDiscovery = discovery;
    }
    final HubAddressResolver? resolver = discovery == null
        ? null
        : HubAddressResolver(
            hasOverride: hasHubBaseUrlOverride,
            overrideBaseUrl: defaultHubBaseUrl,
            fallbackBaseUrl: defaultHubHost,
            discovery: discovery,
          );

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
        baseUrlReader: address.read,
      );
      command =
          widget.commandClient ??
          _productionCommand(tokens, httpClient, address);
    }

    // With an injected hub client but no live client, pass no live state so the
    // increment-1 test widgets keep their REST-only behaviour.
    final LiveStateClient? live =
        widget.liveStateClient ??
        (widget.hubClient == null
            ? _productionLiveState(tokens, client, address)
            : null);
    _controller = HubStatusController(
      client: client,
      tokens: tokens,
      liveState: live,
      command: command,
      resolver: resolver,
      address: address,
    );
    _controller.connect();
  }

  LightCommandClient _productionCommand(
    TokenStore tokens,
    http.Client httpClient,
    HubAddress address,
  ) {
    return HttpLightCommandClient(
      client: httpClient,
      tokenReader: tokens.readToken,
      baseUrlReader: address.read,
    );
  }

  LiveStateClient _productionLiveState(
    TokenStore tokens,
    HubClient client,
    HubAddress address,
  ) {
    final WsLiveStateClient live = WsLiveStateClient(
      baseUrlReader: address.read,
      tokenReader: tokens.readToken,
      hubClient: client,
    );
    _ownedLiveState = live;
    return live;
  }

  /// The platform mDNS search holds a Wi-Fi multicast lock on Android, so it is
  /// stopped while the app is in the background and started again when the app
  /// comes back. The LAN may have changed meanwhile, so a hub that is not
  /// connected re-resolves its address.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        unawaited(_ownedDiscovery?.stop());
      case AppLifecycleState.resumed:
        unawaited(_controller.refreshAddress());
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
        break;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.dispose();
    unawaited(_ownedLiveState?.stop());
    unawaited(_ownedDiscovery?.stop());
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
            final double headerMax = math.max(
              0.0,
              constraints.maxHeight - _listGap,
            );
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
                                        unawaited(_controller.saveToken(token));
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
