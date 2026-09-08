import 'dart:convert';

import 'package:http/http.dart' as http;

import 'session_store.dart';

const familyDocumentsApiBaseUrl = String.fromEnvironment(
  'FAMILYDOCUMENTS_API_BASE_URL',
  defaultValue: 'https://api-familydocuments.servicehub.co.nz',
);

class AuthException implements Exception {
  AuthException(this.message, {this.expired = false});
  final String message;
  final bool expired;
}

class Session {
  Session({
    required this.accessToken,
    required this.refreshToken,
    required this.email,
    required this.userId,
  });
  final String accessToken, refreshToken, email;
  final String? userId;
}

class AuthService {
  AuthService({http.Client? client, SessionStore? store})
    : _client = client ?? http.Client(),
      _store = store ?? createSessionStore();
  static const baseUrl = '$familyDocumentsApiBaseUrl/auth';
  final http.Client _client;
  final SessionStore _store;
  Session? _session;
  Future<Session>? _refreshing;
  Session? get session => _session;
  Future<Session> signIn(String email, String password) async {
    final s = await _token({'email': email, 'password': password}, 'password');
    await _store.writeRefreshToken(s.refreshToken);
    _session = s;
    return s;
  }

  Future<Session?> restore() async {
    final token = await _store.readRefreshToken();
    if (token == null) return null;
    try {
      return await refresh(token);
    } catch (_) {
      await clear();
      return null;
    }
  }

  Future<Session> refresh([String? token]) {
    if (_refreshing != null) return _refreshing!;
    _refreshing = _refreshInternal(token ?? _session?.refreshToken ?? '');
    return _refreshing!.whenComplete(() => _refreshing = null);
  }

  Future<Session> _refreshInternal(String token) async {
    if (token.isEmpty) {
      throw AuthException('Your session has expired.', expired: true);
    }
    try {
      final s = await _token({'refresh_token': token}, 'refresh_token');
      await _store.writeRefreshToken(s.refreshToken);
      _session = s;
      return s;
    } catch (_) {
      await clear();
      throw AuthException('Your session has expired.', expired: true);
    }
  }

  Future<Session> _token(Map<String, String> body, String grant) async {
    http.Response r;
    try {
      r = await _client.post(
        Uri.parse('$baseUrl/token?grant_type=$grant'),
        headers: {'content-type': 'application/json'},
        body: jsonEncode(body),
      );
    } catch (_) {
      throw AuthException(
        'We could not reach FamilyDocuments. Please try again.',
      );
    }
    if (r.statusCode != 200) {
      throw AuthException('Check your email and password, then try again.');
    }
    final b = jsonDecode(r.body) as Map<String, dynamic>;
    final access = b['access_token'] as String?;
    final refresh = b['refresh_token'] as String?;
    final user = b['user'] as Map<String, dynamic>?;
    if (access == null || refresh == null || user?['email'] == null) {
      throw AuthException('Authentication response was incomplete.');
    }
    return Session(
      accessToken: access,
      refreshToken: refresh,
      email: user!['email'] as String,
      userId: user['id']?.toString(),
    );
  }

  bool get expiresSoon {
    final t = _session?.accessToken;
    if (t == null) return true;
    try {
      final p = jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(t.split('.')[1]))),
      ) as Map;
      final exp = p['exp'] as num?;
      return exp == null ||
          DateTime.fromMillisecondsSinceEpoch(exp.toInt() * 1000)
              .isBefore(DateTime.now().add(const Duration(seconds: 30)));
    } catch (_) {
      return true;
    }
  }

  Future<String> validAccessToken() async {
    if (_session == null) throw AuthException('Sign in is required.');
    if (expiresSoon) await refresh();
    return _session!.accessToken;
  }

  Future<void> signOut() async {
    final current = _session;
    await clear();
    if (current == null) return;
    try {
      await _client.post(
        Uri.parse('$baseUrl/logout'),
        headers: {
          'authorization': 'Bearer ${current.accessToken}',
          'content-type': 'application/json',
        },
      );
    } catch (_) {}
  }

  Future<void> clear() async {
    _session = null;
    await _store.clear();
  }
}
