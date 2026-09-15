import 'package:familydocuments_flutter/features/settings/telegram/telegram_integration_page.dart';
import 'package:familydocuments_flutter/features/settings/telegram/telegram_integration_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeTelegramRepository implements TelegramIntegrationRepository {
  FakeTelegramRepository({
    this.connected = false,
    this.state,
    this.failures = 0,
  });
  bool connected;
  TelegramConnectionState? state;
  int failures;
  int connectCalls = 0, disconnectCalls = 0, statusCalls = 0;
  @override
  Future<TelegramConnection> status() async {
    statusCalls++;
    if (failures > 0) {
      failures--;
      throw const TelegramIntegrationException(
        'Telegram could not be reached. Try again.',
      );
    }
    return TelegramConnection(
      connected: connected,
      state: state,
      selectionRequired: false,
      familyId: '11111111-1111-4111-8111-111111111111',
      familyName: 'Test Family',
      displayName: connected ? 'Test Person' : null,
    );
  }

  @override
  Future<TelegramConnectLink> connect(String familyId) async {
    connectCalls++;
    state = TelegramConnectionState.linkPending;
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

  testWidgets('unconfigured staging transport explains setup is incomplete', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(home: TelegramIntegrationPage(repository: _UnavailableRepository())),
    );
    await tester.pumpAndSettle();
    expect(
      find.text('Telegram setup is not complete for this staging environment yet.'),
      findsOneWidget,
    );
    expect(find.text('Connect Telegram'), findsNothing);
  });

  testWidgets('pending, disconnected and revoked states render safely', (
    tester,
  ) async {
    for (final state in [
      TelegramConnectionState.linkPending,
      TelegramConnectionState.disconnected,
      TelegramConnectionState.membershipRevoked,
    ]) {
      await tester.pumpWidget(
        MaterialApp(
          home: TelegramIntegrationPage(
            key: ValueKey(state),
            repository: FakeTelegramRepository(state: state),
          ),
        ),
      );
      await tester.pumpAndSettle();
      switch (state) {
        case TelegramConnectionState.linkPending:
          expect(find.text('Link pending'), findsOneWidget);
          expect(find.text('Generate a new link'), findsOneWidget);
        case TelegramConnectionState.disconnected:
          expect(find.text('Disconnected'), findsOneWidget);
          expect(find.text('Reconnect Telegram'), findsOneWidget);
        case TelegramConnectionState.membershipRevoked:
          expect(find.textContaining('Family access changed'), findsOneWidget);
        case TelegramConnectionState.notConnected:
        case TelegramConnectionState.connected:
          fail('unexpected test state');
      }
    }
  });

  testWidgets('temporary status failure offers a working retry', (
    tester,
  ) async {
    final repository = FakeTelegramRepository(failures: 1);
    await tester.pumpWidget(
      MaterialApp(home: TelegramIntegrationPage(repository: repository)),
    );
    await tester.pumpAndSettle();
    expect(
      find.text('Telegram could not be reached. Try again.'),
      findsOneWidget,
    );
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.text('Not connected'), findsOneWidget);
    expect(repository.statusCalls, 2);
  });

  testWidgets('a new integration route never reuses prior-user status', (
    tester,
  ) async {
    final first = FakeTelegramRepository(connected: true);
    await tester.pumpWidget(
      MaterialApp(home: TelegramIntegrationPage(repository: first)),
    );
    await tester.pumpAndSettle();
    expect(find.text('Test Person'), findsOneWidget);
    final second = FakeTelegramRepository();
    await tester.pumpWidget(
      MaterialApp(
        home: TelegramIntegrationPage(
          key: const ValueKey('new-user-telegram-route'),
          repository: second,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Test Person'), findsNothing);
    expect(find.text('Not connected'), findsOneWidget);
    expect(second.statusCalls, 1);
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

class _UnavailableRepository extends _SelectionRequiredRepository {
  @override
  Future<TelegramConnection> status() async => const TelegramConnection(
    connected: false,
    selectionRequired: false,
    available: false,
  );
}
