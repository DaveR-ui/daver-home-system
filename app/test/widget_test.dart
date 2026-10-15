import 'package:daver_home/hub/hub_client.dart';
import 'package:daver_home/hub/token_store.dart';
import 'package:daver_home/main.dart';
import 'package:daver_home/ui/hub_banner.dart';
import 'package:daver_home/ui/token_entry.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A hub that answers the probe and snapshot instantly, with no entities.
class _ReachableHub implements HubClient {
  @override
  Future<bool> probeHub() async => true;

  @override
  Future<List<EntitySnapshot>> fetchStates() async => const <EntitySnapshot>[];

  @override
  Future<EntitySnapshot> fetchEntity(String entityId) async =>
      throw const HubUnavailableException();
}

class _MemoryTokenStore implements TokenStore {
  _MemoryTokenStore([this.token]);

  String? token;

  @override
  Future<String?> readToken() async => token;

  @override
  Future<void> writeToken(String token) async => this.token = token;

  @override
  Future<void> clearToken() async => token = null;
}

void main() {
  testWidgets('first screen shows the app title and no hub banner when connected',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      DaverApp(hubClient: _ReachableHub(), tokenStore: _MemoryTokenStore('tok')),
    );
    await tester.pumpAndSettle();

    // The title appears in both the app bar and the headline.
    expect(find.text('Daver Home'), findsWidgets);

    expect(find.byType(HubBanner), findsNothing);
    expect(find.text('Hub unavailable'), findsNothing);
    expect(find.text('Connecting to the hub'), findsNothing);
    expect(find.byType(TokenEntryField), findsNothing);
  });

  testWidgets('no stored token asks for one, and saving it connects',
      (WidgetTester tester) async {
    final _MemoryTokenStore tokens = _MemoryTokenStore();
    await tester.pumpWidget(
      DaverApp(hubClient: _ReachableHub(), tokenStore: tokens),
    );
    await tester.pumpAndSettle();

    expect(find.byType(TokenEntryField), findsOneWidget);
    expect(find.text('Hub unavailable'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '  secret  ');
    // The controller's text lands after enterText's own frame; one more frame
    // lets the Save button rebuild enabled.
    await tester.pump();
    await tester.tap(find.text('Save token'));
    await tester.pumpAndSettle();

    expect(tokens.token, 'secret');
    expect(find.byType(TokenEntryField), findsNothing);
    expect(find.byType(HubBanner), findsNothing);
  });
}
