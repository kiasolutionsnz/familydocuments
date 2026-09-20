import 'dart:async';
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';

abstract class PushProvider {
  bool get isSupported;
  bool get isConfigured;
  Future<String> enable();
  Future<void> disable();
  Stream<String> get tokenRefreshes;
}

PushProvider createPushProvider() => FirebasePushProvider();

class FirebasePushProvider implements PushProvider {
  static const apiKey = String.fromEnvironment('FIREBASE_API_KEY');
  static const appId = String.fromEnvironment('FIREBASE_APP_ID');
  static const projectId = String.fromEnvironment('FIREBASE_PROJECT_ID');
  static const senderId = String.fromEnvironment('FIREBASE_MESSAGING_SENDER_ID');
  static const iosBundleId = 'app.familydocuments.mobile';

  FirebaseMessaging? _messaging;

  @override
  bool get isSupported => Platform.isAndroid || Platform.isIOS;
  @override
  bool get isConfigured =>
      apiKey.isNotEmpty &&
      appId.isNotEmpty &&
      projectId.isNotEmpty &&
      senderId.isNotEmpty;

  Future<FirebaseMessaging> _instance() async {
    if (!isSupported || !isConfigured) {
      throw StateError('Push notifications are not configured for this app.');
    }
    if (Firebase.apps.isEmpty) {
      await Firebase.initializeApp(
        options: FirebaseOptions(
          apiKey: apiKey,
          appId: appId,
          messagingSenderId: senderId,
          projectId: projectId,
          iosBundleId: Platform.isIOS ? iosBundleId : null,
        ),
      );
    }
    return _messaging ??= FirebaseMessaging.instance;
  }

  @override
  Future<String> enable() async {
    final messaging = await _instance();
    final settings = await messaging.requestPermission(
      alert: true,
      badge: true,
      sound: true,
      provisional: false,
    );
    if (settings.authorizationStatus != AuthorizationStatus.authorized &&
        settings.authorizationStatus != AuthorizationStatus.provisional) {
      throw StateError(
        'Notifications are disabled. Allow them in your device settings.',
      );
    }
    await messaging.setAutoInitEnabled(true);
    if (Platform.isIOS) {
      for (var attempt = 0; attempt < 10; attempt++) {
        if (await messaging.getAPNSToken() != null) break;
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      if (await messaging.getAPNSToken() == null) {
        throw StateError(
          'Apple notification registration is not ready. Try again shortly.',
        );
      }
    }
    final token = (await messaging.getToken())?.trim() ?? '';
    if (token.isEmpty) throw StateError('A notification token was not issued.');
    return token;
  }

  @override
  Stream<String> get tokenRefreshes async* {
    final messaging = await _instance();
    yield* messaging.onTokenRefresh.where((token) => token.trim().isNotEmpty);
  }

  @override
  Future<void> disable() async {
    final messaging = await _instance();
    await messaging.deleteToken();
    await messaging.setAutoInitEnabled(false);
  }
}
