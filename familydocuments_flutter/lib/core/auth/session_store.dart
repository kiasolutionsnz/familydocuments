import 'session_store_stub.dart'
    if (dart.library.html) 'session_store_web.dart'
    if (dart.library.io) 'session_store_native.dart';

abstract class SessionStore {
  Future<String?> readRefreshToken();
  Future<void> writeRefreshToken(String token);
  Future<void> clear();
}

SessionStore createSessionStore() => createPlatformSessionStore();
