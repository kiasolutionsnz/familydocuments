import 'package:familydocuments_flutter/features/settings/telegram/telegram_integration_page.dart';
import 'package:familydocuments_flutter/features/settings/telegram/telegram_integration_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeTelegramRepository implements TelegramIntegrationRepository {
  FakeTelegramRepository({this.connected = false});
  bool connected;
  int connectCalls = 0, disconnectCalls = 0;
  @override
  Future<TelegramConnection> status() async => TelegramConnection(
    connected: connected,
    selectionRequired: false,
    familyId: '11111111-1111-4111-8111-111111111111',
    familyName: 'Test Family',
    displayName: connected ? 'Test Person' : null,
  );
  @override
  Future<TelegramConnectLink> connect(String familyId) async {
    connectCalls++;
    return TelegramConnectLink(
      url: 'https://t.me/TestFamilyDocumentsBot?start=${'a' * 43}',
      expiresAt: DateTime.now().add(const Duration(minutes: 10)),
    );
  }

  @override
  Future<void> disconnect(String familyId) async {
    disconnectCalls++;
    connected = false;
  }
}

void main() {
  testWidgets('shows active Family and creates an expiring Telegram link', (
    tester,
  ) async {
    final repository = FakeTelegramRepository();
    await tester.pumpWidget(
      MaterialApp(home: TelegramIntegrationPage(repository: repository)),
    );
    await tester.pumpAndSettle();
    expect(find.text('Family: Test Family'), findsOneWidget);
    expect(find.text('Not connected'), findsOneWidget);
    await tester.tap(find.text('Connect Telegram'));
    await tester.pumpAndSettle();
    expect(repository.connectCalls, 1);
    expect(find.text('Open Telegram'), findsOneWidget);
    expect(find.textContaining('expires in 10 minutes'), findsOneWidget);
  });

  testWidgets('disconnect requires confirmation and refreshes status', (
    tester,
  ) async {
    final repository = FakeTelegramRepository(connected: true);
    await tester.pumpWidget(
      MaterialApp(home: TelegramIntegrationPage(repository: repository)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Disconnect'));
    await tester.pumpAndSettle();
    expect(find.text('Disconnect Telegram?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Disconnect'));
    await tester.pumpAndSettle();
    expect(repository.disconnectCalls, 1);
    expect(find.text('Not connected'), findsOneWidget);
  });

  testWidgets('multiple-Family selection is required before linking', (
    tester,
  ) async {
    final repository = _SelectionRequiredRepository();
    await tester.pumpWidget(
      MaterialApp(home: TelegramIntegrationPage(repository: repository)),
    );
    await tester.pumpAndSettle();
    expect(
      find.text('Choose an active Family before connecting Telegram.'),
      findsOneWidget,
    );
    expect(find.text('Connect Telegram'), findsNothing);
  });
}

class _SelectionRequiredRepository implements TelegramIntegrationRepository {
  @override
  Future<TelegramConnection> status() async =>
      const TelegramConnection(connected: false, selectionRequired: true);
  @override
  Future<TelegramConnectLink> connect(String familyId) =>
      throw UnimplementedError();
  @override
  Future<void> disconnect(String familyId) => throw UnimplementedError();
}
