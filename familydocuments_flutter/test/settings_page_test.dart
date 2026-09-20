import 'package:familydocuments_flutter/core/auth/auth_service.dart';
import 'package:familydocuments_flutter/features/settings/settings_page.dart';
import 'package:familydocuments_flutter/features/settings/notifications/push_notification_service.dart';
import 'package:familydocuments_flutter/features/settings/telegram/telegram_integration_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _TelegramRepository implements TelegramIntegrationRepository {
  @override
  Future<TelegramConnectLink> connect(String familyId) async =>
      TelegramConnectLink(
        url: 'https://t.me/FamilyDocumentsTestBot?start=${'a' * 43}',
        expiresAt: DateTime.now().add(const Duration(minutes: 10)),
      );

  @override
  Future<void> disconnect(String familyId) async {}

  @override
  Future<TelegramConnection> status() async => const TelegramConnection(
    connected: false,
    selectionRequired: false,
    familyId: '11111111-1111-4111-8111-111111111111',
    familyName: 'Test Family',
  );
}

class _PushRepository implements PushNotificationRepository {
  @override bool get configured => true;
  @override bool get supported => true;
  @override Future<bool> loadEnabled() async => false;
  @override Future<void> enable() async {}
  @override Future<void> disable() async {}
  @override void dispose() {}
}

void main() {
  testWidgets('makes forwarding and allowed senders prominent', (tester) async {
    await tester.pumpWidget(
      MaterialApp(home: SettingsPage(auth: AuthService())),
    );

    expect(find.text('Email forwarding and allowed senders'), findsOneWidget);
    expect(
      find.text('Manage your forwarding address and trusted sender list'),
      findsOneWidget,
    );
  });

  testWidgets('opens the Telegram private-chat connection flow', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SettingsPage(
          auth: AuthService(),
          telegramRepository: _TelegramRepository(),
        ),
      ),
    );

    expect(
      find.text('Connect the FamilyDocuments bot privately'),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('telegram-integration')));
    await tester.pumpAndSettle();

    expect(
      find.text('Use the FamilyDocuments bot in a private Telegram chat.'),
      findsOneWidget,
    );
    expect(find.text('Connect Telegram'), findsOneWidget);
  });

  testWidgets('opens phone reminder notification settings', (tester) async {
    await tester.pumpWidget(MaterialApp(home: SettingsPage(auth: AuthService(), pushRepository: _PushRepository())));
    await tester.tap(find.byKey(const ValueKey('push-notification-settings')));
    await tester.pumpAndSettle();
    expect(find.text('Push reminder notifications'), findsOneWidget);
  });
}
