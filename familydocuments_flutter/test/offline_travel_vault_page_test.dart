import 'dart:typed_data';

import 'package:familydocuments_flutter/features/library/offline/offline_travel_models.dart';
import 'package:familydocuments_flutter/features/library/offline/offline_travel_vault_page.dart';
import 'package:familydocuments_flutter/features/library/offline/offline_vault_authenticator_models.dart';
import 'package:familydocuments_flutter/core/auth/auth_service.dart';
import 'package:familydocuments_flutter/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Authenticator implements OfflineVaultAuthenticator {
  _Authenticator(this.accepted);
  bool accepted;
  int calls = 0;

  @override
  Future<bool> authenticate() async {
    calls++;
    return accepted;
  }

  @override
  Future<bool> isSupported() async => true;
}

class _Store implements OfflineTravelStore {
  final document = OfflineTravelDocument(
    documentId: 'passport',
    tripId: 'fiji',
    tripTitle: 'Fiji 2027',
    title: 'Passport copy',
    fileName: 'passport.jpg',
    mimeType: 'image/jpeg',
    savedAt: DateTime(2027, 1, 1),
    expiresAt: DateTime(2027, 3, 1),
  );

  @override
  bool get supported => true;
  @override
  Future<List<OfflineTravelDocument>> list(String tripId) async => [document];
  @override
  Future<List<OfflineTravelDocument>> listAll() async => [document];
  @override
  Future<int> purgeExpired() async => 0;
  @override
  Future<OfflineTravelFile?> read(String documentId) async =>
      OfflineTravelFile(document: document, bytes: Uint8List.fromList([1]));
  @override
  Future<void> remove(String documentId) async {}
  @override
  Future<void> save({
    required String tripId,
    required String tripTitle,
    required String documentId,
    required String title,
    required String fileName,
    required String mimeType,
    required Uint8List bytes,
    required DateTime expiresAt,
  }) async {}
}

class _NoSessionAuth extends AuthService {
  @override
  Session? get session => null;

  @override
  Future<Session?> restore() async => null;
}

void main() {
  testWidgets(
    'signed-out mobile user can enter only the protected offline vault',
    (tester) async {
      final authentication = _Authenticator(true);
      await tester.pumpWidget(
        FamilyDocumentsApp(
          auth: _NoSessionAuth(),
          offlineTravelStore: _Store(),
          offlineVaultAuthenticator: authentication,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Open offline travel pack'), findsOneWidget);
      expect(find.text('Passport copy'), findsNothing);
      await tester.tap(find.text('Open offline travel pack'));
      await tester.pumpAndSettle();
      expect(find.text('Passport copy'), findsOneWidget);
      expect(authentication.calls, 1);
    },
  );

  testWidgets('device authentication unlocks an offline travel pack', (
    tester,
  ) async {
    final authentication = _Authenticator(true);
    await tester.pumpWidget(
      MaterialApp(
        home: OfflineTravelVaultPage(
          store: _Store(),
          authenticator: authentication,
          onClose: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(authentication.calls, 1);
    expect(find.text('Passport copy'), findsOneWidget);
    expect(find.textContaining('Fiji 2027'), findsOneWidget);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(find.text('Unlock travel pack'), findsOneWidget);
  });

  testWidgets('failed device authentication reveals no document names', (
    tester,
  ) async {
    final authentication = _Authenticator(false);
    await tester.pumpWidget(
      MaterialApp(
        home: OfflineTravelVaultPage(
          store: _Store(),
          authenticator: authentication,
          onClose: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Passport copy'), findsNothing);
    expect(find.text('Unlock travel pack'), findsOneWidget);
  });
}
