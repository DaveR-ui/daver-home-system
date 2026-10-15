import 'package:daver_home/hub_status.dart';
import 'package:daver_home/ui/hub_banner.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const Map<HubStatus, String> labels = <HubStatus, String>{
    HubStatus.connecting: 'Connecting to the hub',
    HubStatus.hubUnavailable: 'Hub unavailable',
    HubStatus.offline: 'Phone offline',
  };

  for (final MapEntry<HubStatus, String> entry in labels.entries) {
    testWidgets('${entry.key.name} shows "${entry.value}"', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: HubBanner(status: entry.key))),
      );

      expect(find.text(entry.value), findsOneWidget);
    });
  }
}
