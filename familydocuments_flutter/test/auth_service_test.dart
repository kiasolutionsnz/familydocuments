import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:familydocuments_flutter/core/auth/auth_service.dart';
import 'package:familydocuments_flutter/core/auth/session_store.dart';

class MemoryStore implements SessionStore {
  String? value;
  int writes = 0;
  @override
  Future<void> clear() async => value = null;
  @override
  Future<String?> readRefreshToken() async => value;
  @override
  Future<void> writeRefreshToken(String token) async {
    writes++;
    value = token;
  }
}

class FakeClient extends http.BaseClient {
  FakeClient(this.handler);
  final Future<http.Response> Function(http.BaseRequest) handler;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest r) async {
    final x = await handler(r);
    return http.StreamedResponse(
      Stream.value(x.bodyBytes),
      x.statusCode,
      headers: x.headers,
      request: r,
    );
  }
}

http.Response token(String access, String refresh) => http.Response(
  jsonEncode({
    'access_token': access,
    'refresh_token': refresh,
    'user': {'id': 'u1', 'email': 'ava@example.com'},
  }),
  200,
);
String jwt(int seconds) =>
    'x.${base64Url.encode(utf8.encode(jsonEncode({'exp': DateTime.now().add(Duration(seconds: seconds)).millisecondsSinceEpoch ~/ 1000}))).replaceAll('=', '')}.x';
void main() {
  test('sign up sends profile details without creating a local session', () async {
    final store = MemoryStore();
    final auth = AuthService(
      store: store,
      client: FakeClient((request) async {
        expect(request.url.path, '/auth/signup');
        final body = jsonDecode(await request.finalize().bytesToString()) as Map;
        expect(body['email'], 'ava@example.com');
        expect(body['password'], 'a long secret password');
        expect((body['data'] as Map)['display_name'], 'Ava');
        return http.Response('{}', 200);
      }),
    );
    await auth.signUp(' ava@example.com ', 'a long secret password', ' Ava ');
    expect(auth.session, isNull);
    expect(store.writes, 0);
  });
  test('sign in stores only refresh token', () async {
    final s = MemoryStore();
    final a = AuthService(
      store: s,
      client: FakeClient((_) async => token(jwt(3600), 'refresh')),
    );
    await a.signIn('a', 'p');
    expect(s.value, 'refresh');
    expect(s.value, isNot(contains('x.')));
  });
  test('stored token restores session', () async {
    final s = MemoryStore()..value = 'old';
    final a = AuthService(
      store: s,
      client: FakeClient((_) async => token(jwt(3600), 'new')),
    );
    expect((await a.restore())!.email, 'ava@example.com');
  });
  test(
    'expired concurrent requests share one refresh and receive new token',
    () async {
      var calls = 0;
      final s = MemoryStore();
      final a = AuthService(
        store: s,
        client: FakeClient((_) async {
          calls++;
          return token(jwt(calls == 1 ? -60 : 3600), 'next');
        }),
      );
      await a.signIn('a', 'p');
      final results = await Future.wait([
        a.validAccessToken(),
        a.validAccessToken(),
      ]);
      expect(calls, 2); // One sign-in request and one shared refresh request.
      expect(results[0], results[1]);
    },
  );
  test('failed refresh clears stored session', () async {
    final s = MemoryStore()..value = 'old';
    final a = AuthService(
      store: s,
      client: FakeClient((_) async => http.Response('{}', 401)),
    );
    expect(await a.restore(), isNull);
    expect(s.value, isNull);
  });
  test('sign out clears locally when logout fails', () async {
    final s = MemoryStore();
    var calls = 0;
    final a = AuthService(
      store: s,
      client: FakeClient((_) async {
        calls++;
        if (calls == 1) return token(jwt(3600), 'refresh');
        throw Exception();
      }),
    );
    await a.signIn('a', 'p');
    await a.signOut();
    expect(s.value, isNull);
    expect(a.session, isNull);
  });
}
