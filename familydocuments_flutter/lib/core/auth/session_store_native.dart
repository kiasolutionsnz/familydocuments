import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'session_store.dart';

class _Store implements SessionStore {
  final _storage = const FlutterSecureStorage();
  static const _key = 'familydocuments.refresh-token';
  @override
  Future<void> clear() => _storage.delete(key: _key);
  @override
  Future<String?> readRefreshToken() => _storage.read(key: _key);
  @override
  Future<void> writeRefreshToken(String token) =>
      _storage.write(key: _key, value: token);
}

SessionStore createPlatformSessionStore() => _Store();
