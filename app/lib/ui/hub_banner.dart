import 'package:flutter/material.dart';

import '../hub_status.dart';

/// The status surface the owner calls the "cartel".
///
/// A stand-in seam for the future hub client: it renders the app's model of
/// hub reachability ([HubStatus]) as an icon, a short label, and a one-line
/// explanation. It never invents hub state; once a client exists the same
/// enum is driven by the real probe and WebSocket state.
class HubBanner extends StatelessWidget {
  const HubBanner({super.key, required this.status});

  /// The app's current model of hub reachability.
  final HubStatus status;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final _BannerStyle style = _BannerStyle.of(status, scheme);

    return Semantics(
      container: true,
      excludeSemantics: true,
      label: '${style.label}. ${style.explanation}',
      child: Card(
        color: style.background,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Icon(style.icon, color: style.foreground),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      style.label,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            color: style.foreground,
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      style.explanation,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: style.foreground,
                          ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Presentation mapping for a single [HubStatus] value.
class _BannerStyle {
  const _BannerStyle({
    required this.label,
    required this.explanation,
    required this.icon,
    required this.background,
    required this.foreground,
  });

  final String label;
  final String explanation;
  final IconData icon;
  final Color background;
  final Color foreground;

  static _BannerStyle of(HubStatus status, ColorScheme scheme) {
    return switch (status) {
      HubStatus.connecting => _BannerStyle(
          label: 'Connecting to the hub',
          explanation: 'Contacting Home Assistant and waiting for live state.',
          icon: Icons.sync,
          background: scheme.secondaryContainer,
          foreground: scheme.onSecondaryContainer,
        ),
      HubStatus.hubUnavailable => _BannerStyle(
          label: 'Hub unavailable',
          explanation: 'Home Assistant cannot be reached; state may be stale.',
          icon: Icons.cloud_off,
          background: scheme.errorContainer,
          foreground: scheme.onErrorContainer,
        ),
      HubStatus.offline => _BannerStyle(
          label: 'Phone offline',
          explanation: 'This device has no network, so the hub is unreachable.',
          icon: Icons.wifi_off,
          background: scheme.surfaceContainerHighest,
          foreground: scheme.onSurfaceVariant,
        ),
    };
  }
}
