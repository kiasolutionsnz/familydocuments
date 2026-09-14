import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:familydocuments_flutter/core/auth/auth_service.dart';
import 'package:familydocuments_flutter/core/auth/session_store.dart';

class MemoryStore implements SessionStore {
  String? refreshToken;
  @override
  Future<void> clear() async {
    refreshToken = null;
  }

  @override
  Future<String?> readRefreshToken() async => refreshToken;
  @override
  Future<void> writeRefreshToken(String token) async {
    refreshToken = token;
  }
}

String token(String aal) =>
    'synthetic.${base64Url.encode(utf8.encode(jsonEncode({'exp': 4102444800, 'aal': aal})))}.signature';
Map<String, dynamic> session(String aal) => {
  'access_token': token(aal),
  'refresh_token': 'fake-refresh-$aal',
  'user': {
    'id': 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
    'email': 'synthetic@example.test',
  },
};
void main() {
  test('MFA replaces session and persists only refresh token', () async {
    final store = MemoryStore();
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/token')) {
        return http.Response(jsonEncode(session('aal1')), 200);
      }
      expect(request.headers['authorization'], 'Bearer ${token('aal1')}');
      if (request.url.path.endsWith('/challenge')) {
        return http.Response('{"id":"synthetic-challenge"}', 200);
      }
      expect(jsonDecode(request.body), {
        'challenge_id': 'synthetic-challenge',
        'code': '123456',
      });
      return http.Response(jsonEncode(session('aal2')), 200);
    });
    final auth = AuthService(client: client, store: store);
    await auth.signIn('synthetic@example.test', 'fake-password');
    await auth.verifyTotp('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', '123456');
    expect(await auth.validAccessToken(), token('aal2'));
    expect(store.refreshToken, 'fake-refresh-aal2');
  });
  test('invalid MFA response never upgrades current session', () async {
    final store = MemoryStore();
    final auth = AuthService(
      store: store,
      client: MockClient((request) async {
        if (request.url.path.endsWith('/token')) {
          return http.Response(jsonEncode(session('aal1')), 200);
        }
        return http.Response('{}', 403);
      }),
    );
    await auth.signIn('synthetic@example.test', 'fake-password');
    await expectLater(
      auth.verifyTotp('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', '123456'),
      throwsA(isA<AuthException>()),
    );
    expect(store.refreshToken, 'fake-refresh-aal1');
    expect(await auth.validAccessToken(), token('aal1'));
  });
}
