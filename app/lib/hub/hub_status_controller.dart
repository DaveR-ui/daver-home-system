import 'package:flutter/foundation.dart';

import '../hub_status.dart';
import 'hub_client.dart';
import 'token_store.dart';

/// Drives the app's [HubStatus] from the real probe and snapshot results.
///
/// The status is the only reachability model the UI reads. [entities] is a
/// render cache of the last good snapshot, never a second source of truth:
/// Home Assistant stays the state authority (ADR-0005).
final class HubStatusController extends ChangeNotifier {
  HubStatusController({required this.client, required this.tokens});

  final HubClient client;
  final TokenStore tokens;

  /// Null means connected; the banner is hidden in that case.
  HubStatus? _status = HubStatus.connecting;
  bool _needsToken = false;
  List<EntitySnapshot> _entities = const <EntitySnapshot>[];
  bool _disposed = false;

  /// Counts connect attempts so a slow, stale attempt cannot overwrite a newer one.
  int _attempt = 0;

  /// The current reachability; null when connected.
  HubStatus? get status => _status;

  bool get isConnected => _status == null;

  /// True when no token is stored, so the UI should ask for one.
  bool get needsToken => _needsToken;

  /// The last good `GET /api/states` snapshot, for rendering only.
  List<EntitySnapshot> get entities => _entities;

  /// Probes the hub and, when it answers, caches the entity snapshot.
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

    // The probe succeeded, so the hub is connected even if the snapshot fails.
    // The previous cache is kept; the banner is hidden only on a connected hub.
    try {
      final List<EntitySnapshot> states = await client.fetchStates();
      if (attempt != _attempt) {
        return;
      }
      _entities = List<EntitySnapshot>.unmodifiable(states);
    } on Object {
      // Deliberately ignored: the snapshot is a cache, and the probe already passed.
    }
    if (attempt != _attempt) {
      return;
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
    super.dispose();
  }
}
