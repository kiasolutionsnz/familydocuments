// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;

import 'session_store.dart';

class _Store implements SessionStore {
  static const _key = 'familydocuments.refresh-token';
  @override
  Future<void> clear() async {
    html.window.sessionStorage.remove(_key);
  }

  @override
  Future<String?> readRefreshToken() async => html.window.sessionStorage[_key];
  @override
  Future<void> writeRefreshToken(String token) async {
    html.window.sessionStorage[_key] = token;
  }
}

SessionStore createPlatformSessionStore() => _Store();
