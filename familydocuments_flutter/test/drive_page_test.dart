import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:familydocuments_flutter/core/auth/auth_service.dart';
import 'package:familydocuments_flutter/features/settings/drive/drive_page.dart';
import 'package:familydocuments_flutter/features/settings/drive/drive_service.dart';
import 'package:qr_flutter/qr_flutter.dart';

class FakeDrive extends DriveRepository {
  DriveConnectionState state = DriveConnectionState.notConnected;
  bool admin = true, fail = false;
  int statusCalls = 0, connections = 0, selections = 0, disconnections = 0;
  final items = <DriveFolder>[
    const DriveFolder('synthetic-folder-1', 'Family files'),
  ];
  @override
  Future<DriveConnection> status() async {
    statusCalls++;
    if (fail) throw const DriveException('Connection unavailable. Try again.');
    return DriveConnection(
      state: state,
      familyId: 'family-one',
      canManage: admin,
      folderName: state == DriveConnectionState.connected
          ? 'Family files'
          : null,
    );
  }

  @override
  Future<void> connect(String code) async {
    connections++;
    state = DriveConnectionState.chooseFolder;
  }

  @override
  Future<List<DriveFolder>> folders() async => items;
  @override
  Future<DriveFolder> createFolder(String name) async =>
      DriveFolder('created-folder', name);
  @override
  Future<void> selectFolder(String id) async {
    selections++;
    state = DriveConnectionState.connected;
  }

  @override
  Future<void> disconnect() async {
    disconnections++;
    state = DriveConnectionState.disconnected;
  }
}

class FakeDriveAuth extends AuthService {
  int verifications = 0;
  @override
  Future<List<Map<String, dynamic>>> totpFactors() async => [
    {'id': 'synthetic-factor'},
  ];
  @override
  Future<void> verifyTotp(String factorId, String code) async {
    verifications++;
  }
}

class FakeEnrollDriveAuth extends FakeDriveAuth {
  FakeEnrollDriveAuth({this.includeUri = true});
  final bool includeUri;

  @override
  Future<List<Map<String, dynamic>>> totpFactors() async => [];

  @override
  Future<Map<String, dynamic>> enrollTotp() async => {
    'id': 'synthetic-factor',
    'totp': {
      'secret': 'SYNTHETICSETUPKEY',
      if (includeUri) 'uri': 'otpauth://totp/FamilyDocuments:test?secret=SYNTHETICSETUPKEY&issuer=FamilyDocuments',
    },
  };
}

Future<void> mount(
  WidgetTester tester,
  FakeDrive drive, {
  AuthService? auth,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: DrivePage(
        auth: auth ?? FakeDriveAuth(),
        repository: drive,
        clientId: 'synthetic-client',
        prepareAuthorization: () async {},
        authorize: (_) async => 'synthetic-code',
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> verify(WidgetTester tester) async {
  await tester.tap(find.text('Verify identity to manage Drive'));
  // The parent retains its in-flight guard while the verification dialog is open.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.enterText(find.byType(TextField), '123456');
  await tester.tap(find.text('Verify'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'new authenticator setup shows a scannable QR and hides the key by default',
    (tester) async {
      await mount(tester, FakeDrive(), auth: FakeEnrollDriveAuth());
      await tester.tap(find.text('Verify identity to manage Drive'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(QrImageView), findsOneWidget);
      expect(find.text('SYNTHETICSETUPKEY'), findsNothing);
      await tester.ensureVisible(find.text('Use setup key instead'));
      await tester.pump();
      await tester.tap(find.text('Use setup key instead'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('SYNTHETICSETUPKEY'), findsOneWidget);
    },
  );

  testWidgets('manual setup key remains available if Auth omits a QR URI', (
    tester,
  ) async {
    await mount(
      tester,
      FakeDrive(),
      auth: FakeEnrollDriveAuth(includeUri: false),
    );
    await tester.tap(find.text('Verify identity to manage Drive'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(QrImageView), findsNothing);
    expect(find.text('SYNTHETICSETUPKEY'), findsOneWidget);
  });

  testWidgets('QR setup stays usable on a narrow phone screen', (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await mount(tester, FakeDrive(), auth: FakeEnrollDriveAuth());
    await tester.tap(find.text('Verify identity to manage Drive'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(QrImageView), findsOneWidget);
    await tester.ensureVisible(find.byType(TextField));
    expect(find.byType(TextField), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('not connected requires identity verification before Google', (
    tester,
  ) async {
    final drive = FakeDrive();
    await mount(tester, drive);
    expect(find.text('Not connected'), findsOneWidget);
    expect(find.text('Connect Google Drive'), findsNothing);
    await verify(tester);
    await tester.tap(find.text('Connect Google Drive'));
    await tester.pumpAndSettle();
    expect(drive.connections, 1);
    expect(find.text('Choose a folder'), findsOneWidget);
    await tester.tap(find.text('Family files'));
    await tester.pumpAndSettle();
    expect(drive.selections, 1);
    expect(find.text('Connected'), findsOneWidget);
  });
  testWidgets('read-only member can see status but cannot manage', (
    tester,
  ) async {
    final drive = FakeDrive()..admin = false;
    await mount(tester, drive);
    expect(find.textContaining('Ask a Family administrator'), findsOneWidget);
    expect(find.text('Verify identity to manage Drive'), findsNothing);
    expect(find.text('Connect Google Drive'), findsNothing);
  });
  testWidgets('failed status can be refreshed without false success', (
    tester,
  ) async {
    final drive = FakeDrive()..fail = true;
    await mount(tester, drive);
    expect(find.textContaining('Connection unavailable'), findsOneWidget);
    drive.fail = false;
    await tester.tap(find.text('Refresh connection'));
    await tester.pumpAndSettle();
    expect(find.text('Not connected'), findsOneWidget);
  });
  testWidgets('disconnect requires explicit confirmation and reloads status', (
    tester,
  ) async {
    final drive = FakeDrive()..state = DriveConnectionState.connected;
    await mount(tester, drive);
    await verify(tester);
    await tester.tap(find.text('Disconnect'));
    await tester.pumpAndSettle();
    expect(drive.disconnections, 0);
    await tester.tap(find.widgetWithText(FilledButton, 'Disconnect'));
    await tester.pumpAndSettle();
    expect(drive.disconnections, 1);
    expect(find.text('Disconnected'), findsOneWidget);
  });
  for (final width in [360.0, 768.0, 1280.0]) {
    testWidgets('Drive screen fits viewport $width', (tester) async {
      tester.view.physicalSize = Size(width, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await mount(tester, FakeDrive());
      expect(tester.takeException(), isNull);
      expect(find.text('Google Drive'), findsOneWidget);
    });
  }
}
