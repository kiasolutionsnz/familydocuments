import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:familydocuments_flutter/core/auth/auth_service.dart';
import 'package:familydocuments_flutter/features/settings/drive/drive_service.dart';

class TestAuth extends AuthService {
  String token = 'synthetic-access';
  int refreshes = 0;
  bool signedOut = false;
  @override
  Future<String> validAccessToken() async {
    if (signedOut) throw AuthException('Sign in is required.');
    return token;
  }

  @override
  Future<Session> refresh([String? token]) async {
    refreshes++;
    this.token = 'synthetic-refreshed';
    return Session(
      accessToken: this.token,
      refreshToken: 'synthetic-refresh',
      email: 'synthetic@example.test',
      userId: 'synthetic-user',
    );
  }
}

Map<String, dynamic> connection(String status) => {
  'status': status,
  'household_id': 'synthetic-family',
  'can_manage': false,
  'credential_available': status == 'active',
  'folder_name': null,
};

void main() {
  test(
    'setup mutations bind displayed Family and use existing routes',
    () async {
      final calls = <String>[];
      final service = DriveService(
        TestAuth(),
        client: MockClient((request) async {
          if (request.url.path.contains('/rpc/')) {
            return http.Response(jsonEncode(connection('authorised')), 200);
          }
          calls.add('${request.method} ${request.url.path}');
          expect(request.headers['x-family-context'], 'synthetic-family');
          expect(request.headers['x-requested-with'], 'XmlHttpRequest');
          expect(request.headers['authorization'], 'Bearer synthetic-access');
          if (request.method == 'GET') {
            return http.Response(
              '{"files":[{"id":"synthetic-folder","name":"Family files"}]}',
              200,
            );
          }
          if (request.url.path == '/drive/folders') {
            return http.Response(
              '{"id":"synthetic-created","name":"Family files"}',
              200,
            );
          }
          return http.Response('{"status":"authorised"}', 200);
        }),
      );
      await service.status();
      await service.connect('synthetic-code');
      expect((await service.folders()).single.name, 'Family files');
      await service.createFolder('Family files');
      await service.selectFolder('synthetic-folder');
      await service.disconnect();
      expect(calls, [
        'POST /drive/connect',
        'GET /drive/folders',
        'POST /drive/folders',
        'POST /drive/folders/select',
        'POST /drive/disconnect',
      ]);
    },
  );
  test(
    'mutation requires a current connection view and is never retried blindly',
    () async {
      var mutations = 0;
      final service = DriveService(
        TestAuth(),
        client: MockClient((request) async {
          if (request.url.path.contains('/rpc/')) {
            return http.Response(jsonEncode(connection('active')), 200);
          }
          mutations++;
          return http.Response('{}', 503);
        }),
      );
      await expectLater(service.disconnect(), throwsA(isA<DriveException>()));
      expect(mutations, 0);
      await service.status();
      await expectLater(service.disconnect(), throwsA(isA<DriveException>()));
      expect(mutations, 1);
    },
  );
  for (final entry in {
    'not_connected': DriveConnectionState.notConnected,
    'authorised': DriveConnectionState.chooseFolder,
    'active': DriveConnectionState.connected,
    'reconnect_required': DriveConnectionState.reconnectRequired,
    'disconnected': DriveConnectionState.disconnected,
  }.entries) {
    test('decodes ${entry.key} with empty optional metadata', () {
      final value = DriveConnection.fromJson(connection(entry.key));
      expect(value.state, entry.value);
      expect(value.canSave, entry.key == 'active');
      expect(value.canManage, isFalse);
    });
  }

  test(
    'rejects unknown and incomplete states rather than permitting saving',
    () {
      for (final invalid in [
        connection('unknown'),
        {...connection('active'), 'credential_available': false},
        {...connection('active'), 'household_id': null},
        {...connection('active'), 'can_manage': 'true'},
      ]) {
        expect(() => DriveConnection.fromJson(invalid), throwsFormatException);
      }
    },
  );

  test('status uses current token and no client Family authority', () async {
    final auth = TestAuth();
    final service = DriveService(
      auth,
      client: MockClient((request) async {
        expect(request.method, 'POST');
        expect(
          request.url.path,
          '/rest/rpc/household_google_drive_connection_summary',
        );
        expect(request.headers['authorization'], 'Bearer ${auth.token}');
        expect(jsonDecode(request.body), isEmpty);
        return http.Response(jsonEncode(connection('not_connected')), 200);
      }),
    );
    expect((await service.status()).canSave, isFalse);
    auth.token = 'another-synthetic-token';
    await service.status();
  });

  test('401 refreshes once and uses refreshed token', () async {
    final auth = TestAuth();
    var calls = 0;
    final service = DriveService(
      auth,
      client: MockClient((request) async {
        if (++calls == 1) return http.Response('{}', 401);
        expect(request.headers['authorization'], 'Bearer synthetic-refreshed');
        return http.Response(jsonEncode(connection('active')), 200);
      }),
    );
    expect((await service.status()).canSave, isTrue);
    expect(auth.refreshes, 1);
  });

  test('service failure is retryable and never cached as connected', () async {
    var calls = 0;
    final service = DriveService(
      TestAuth(),
      client: MockClient((_) async {
        if (++calls == 1) return http.Response('private upstream details', 503);
        return http.Response(jsonEncode(connection('not_connected')), 200);
      }),
    );
    await expectLater(service.status(), throwsA(isA<DriveException>()));
    expect((await service.status()).canSave, isFalse);
  });

  test('sign out cannot reuse cached status', () async {
    final auth = TestAuth();
    var calls = 0;
    final service = DriveService(
      auth,
      client: MockClient((_) async {
        calls++;
        return http.Response(jsonEncode(connection('active')), 200);
      }),
    );
    await service.status();
    auth.signedOut = true;
    await expectLater(service.status(), throwsA(isA<AuthException>()));
    expect(calls, 1);
  });

  for (final status in [403, 409]) {
    test('$status fails closed', () async {
      final service = DriveService(
        TestAuth(),
        client: MockClient((_) async => http.Response('{}', status)),
      );
      await expectLater(service.status(), throwsA(isA<DriveException>()));
    });
  }

  test('old null response does not imply connected', () async {
    final service = DriveService(
      TestAuth(),
      client: MockClient((_) async => http.Response('null', 200)),
    );
    await expectLater(service.status(), throwsA(isA<DriveException>()));
  });
}
