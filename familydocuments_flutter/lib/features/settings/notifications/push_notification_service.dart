import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../../core/auth/auth_service.dart';
import 'push_provider.dart';

class PushNotificationException implements Exception {
  const PushNotificationException(this.message);
  final String message;
}

abstract class PushNotificationRepository {
  bool get supported;
  bool get configured;
  Future<bool> loadEnabled();
  Future<void> enable();
  Future<void> disable();
  void dispose();
}

class PushNotificationService implements PushNotificationRepository {
  PushNotificationService(
    this.auth, {
    PushProvider? provider,
    http.Client? client,
  }) : provider = provider ?? createPushProvider(),
       client = client ?? http.Client();

  final AuthService auth;
  final PushProvider provider;
  final http.Client client;
  StreamSubscription<String>? _refreshSubscription;

  @override
  bool get supported => provider.isSupported;
  @override
  bool get configured => provider.isConfigured;

  Future<Map<String, dynamic>> _rpc(
    String operation,
    Map<String, dynamic> body,
  ) async {
    Future<http.Response> send() async => client.post(
      Uri.parse('$familyDocumentsApiBaseUrl/rest/rpc/$operation'),
      headers: {
        'authorization': 'Bearer ${await auth.validAccessToken()}',
        'content-type': 'application/json',
      },
      body: jsonEncode(body),
    );
    try {
      var response = await send().timeout(const Duration(seconds: 20));
      if (response.statusCode == 401) {
        await auth.refresh();
        response = await send().timeout(const Duration(seconds: 20));
      }
      if (response.statusCode != 200) {
        throw const PushNotificationException(
          'Notification settings could not be saved. Try again.',
        );
      }
      return Map<String, dynamic>.from(jsonDecode(response.body) as Map);
    } on AuthException {
      rethrow;
    } on PushNotificationException {
      rethrow;
    } catch (_) {
      throw const PushNotificationException(
        'Notification settings could not be reached. Try again.',
      );
    }
  }

  String get _platform =>
      defaultTargetPlatform == TargetPlatform.iOS ? 'ios' : 'android';

  Future<void> _register(String token) async {
    await _rpc('register_push_device', {
      'device_token': token,
      'device_platform': _platform,
    });
  }

  @override
  Future<bool> loadEnabled() async {
    final result = await _rpc('reminder_delivery_settings', const {});
    return result['push_enabled'] == true;
  }

  @override
  Future<void> enable() async {
    if (!supported || !configured) {
      throw const PushNotificationException(
        'Push notifications are not available in this app build yet.',
      );
    }
    try {
      await _register(await provider.enable());
      await _rpc('set_reminder_push_delivery', {'enabled': true});
      await _refreshSubscription?.cancel();
      _refreshSubscription = provider.tokenRefreshes.listen(
        (token) => _register(token),
      );
    } on PushNotificationException {
      rethrow;
    } catch (error) {
      throw PushNotificationException(error.toString().replaceFirst('Bad state: ', ''));
    }
  }

  @override
  Future<void> disable() async {
    await _rpc('set_reminder_push_delivery', {'enabled': false});
    // Opting out is account-wide for this member, including old installations
    // whose provider token is no longer available on this device.
    await _rpc('disable_all_push_devices', const {});
    await _refreshSubscription?.cancel();
    _refreshSubscription = null;
    if (supported && configured) await provider.disable();
  }

  @override
  void dispose() {
    _refreshSubscription?.cancel();
    client.close();
  }
}
