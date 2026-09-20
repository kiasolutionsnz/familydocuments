import 'dart:convert';

import 'package:familydocuments_flutter/core/auth/auth_service.dart';
import 'package:familydocuments_flutter/features/profile/profile_page.dart';
import 'package:familydocuments_flutter/features/profile/profile_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

class ProfileTestAuth extends AuthService {
  @override
  Session? get session => Session(
    accessToken: 'access',
    refreshToken: 'refresh',
    email: 'ava@example.com',
    userId: '00000000-0000-4000-8000-000000000001',
  );
  @override
  Future<String> validAccessToken() async => 'access';
}

class ProfileClient extends http.BaseClient {
  ProfileClient(this.reply);
  final Future<http.Response> Function(http.BaseRequest) reply;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final response = await reply(request);
    return http.StreamedResponse(
      Stream.value(response.bodyBytes),
      response.statusCode,
    );
  }
}

void main() {
  const profile = {
    'display_name': 'Ava',
    'photo_mime': null,
    'photo_base64': null,
    'families': [
      {
        'name': 'Example Family',
        'role': 'owner',
        'joined_at': '2026-09-01T00:00:00Z',
      },
    ],
  };

  test('profile service reads and saves only the signed-in profile', () async {
    final auth = ProfileTestAuth();
    final paths = <String>[];
    final service = ProfileService(
      auth,
      client: ProfileClient((request) async {
        paths.add(request.url.path);
        expect(request.headers['authorization'], 'Bearer access');
        if (request.url.path.endsWith('save_my_profile')) {
          final body =
              jsonDecode(await request.finalize().bytesToString()) as Map;
          expect(body['new_name'], 'Ava Example');
          expect(body['remove_photo'], false);
        }
        return http.Response(jsonEncode(profile), 200);
      }),
    );
    expect((await service.load()).families.single.name, 'Example Family');
    await service.save(displayName: ' Ava Example ');
    expect(paths, ['/rest/rpc/my_profile', '/rest/rpc/save_my_profile']);
  });

  test('profile service submits authenticated account deletion', () async {
    final service = ProfileService(
      ProfileTestAuth(),
      client: ProfileClient((request) async {
        expect(request.url.path, '/rest/rpc/delete_my_account');
        expect(request.headers['authorization'], 'Bearer access');
        final body =
            jsonDecode(await request.finalize().bytesToString()) as Map;
        expect(body['confirmation'], 'DELETE');
        return http.Response(
          jsonEncode({'deleted': true, 'google_drive_files_deleted': false}),
          200,
        );
      }),
    );

    expect(await service.deleteAccount(), isTrue);
  });

  testWidgets('profile offers editable name, photo and legal links', (
    tester,
  ) async {
    final auth = ProfileTestAuth();
    final service = ProfileService(
      auth,
      client: ProfileClient(
        (_) async => http.Response(jsonEncode(profile), 200),
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: ProfilePage(auth: auth, service: service),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Profile'), findsWidgets);
    expect(find.text('Email: ava@example.com'), findsOneWidget);
    expect(find.text('Example Family'), findsOneWidget);
    expect(find.text('Add or change photo'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Terms of use'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Terms of use'), findsOneWidget);
    expect(find.text('Privacy policy'), findsOneWidget);
    expect(find.text('Save profile'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Delete account'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Delete account'));
    await tester.pumpAndSettle();
    expect(find.text('Delete your account?'), findsOneWidget);
    expect(find.text('Delete account'), findsWidgets);
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Delete account'),
          )
          .onPressed,
      isNull,
    );
    await tester.enterText(
      find.byKey(const ValueKey('account-deletion-confirmation')),
      'DELETE',
    );
    await tester.pump();
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Delete account'),
          )
          .onPressed,
      isNotNull,
    );
  });
}
