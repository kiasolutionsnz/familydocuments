import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../../core/auth/auth_service.dart';
import '../models/reminder_models.dart';

class ReminderServiceException implements Exception {
  const ReminderServiceException(this.message);
  final String message;
}

class ReminderService {
  ReminderService(this._auth, {http.Client? client})
    : _client = client ?? http.Client();
  final AuthService _auth;
  final http.Client _client;

  Future<http.Response> _post(
    String operation,
    Map<String, dynamic> body,
  ) async {
    Future<http.Response> send() async => _client.post(
      Uri.parse('$familyDocumentsApiBaseUrl/rest/rpc/$operation'),
      headers: {
        'authorization': 'Bearer ${await _auth.validAccessToken()}',
        'content-type': 'application/json',
      },
      body: jsonEncode(body),
    );
    try {
      var response = await send();
      if (response.statusCode == 401) {
        await _auth.refresh();
        response = await send();
      }
      return response;
    } on AuthException {
      rethrow;
    } catch (_) {
      throw const ReminderServiceException(
        'Reminders could not be reached. Try again.',
      );
    }
  }

  Future<ReminderDashboard> load() async {
    final dashboardResponse = await _post('reminder_dashboard', const {});
    if (dashboardResponse.statusCode != 200) {
      throw const ReminderServiceException(
        'Reminders could not be loaded. Try again.',
      );
    }
    try {
      final dashboard = ReminderDashboard.fromJson(
        jsonDecode(dashboardResponse.body) as Map,
      );
      // Delivery preferences and history enhance the dashboard but must never
      // make the user's reminders inaccessible when that optional request is
      // briefly unavailable or awaiting a staged schema refresh.
      Map settings = const {'email_enabled': true, 'history': []};
      try {
        final settingsResponse = await _post(
          'reminder_delivery_settings',
          const {},
        );
        if (settingsResponse.statusCode == 200) {
          settings = jsonDecode(settingsResponse.body) as Map;
        }
      } on ReminderServiceException {
        // Keep the reminder list available with the safe default preference.
      }
      return ReminderDashboard(
        items: dashboard.items,
        emailEnabled: settings['email_enabled'] != false,
        deliveryHistory: (settings['history'] as List? ?? const [])
            .whereType<Map>()
            .map(ReminderDelivery.fromJson)
            .toList(),
      );
    } catch (_) {
      throw const ReminderServiceException(
        'Reminders returned an unexpected response.',
      );
    }
  }

  Future<void> act(String id, String action, {String? snoozeUntil}) async {
    final response = await _post('act_on_reminder', {
      'reminder': id,
      'action': action,
      'snooze_until': snoozeUntil,
    });
    if (response.statusCode != 200) {
      throw const ReminderServiceException(
        'That reminder could not be updated. Refresh and try again.',
      );
    }
  }

  Future<void> configure(String id, String recurrence) async {
    final response = await _post('set_reminder_recurrence', {
      'reminder': id,
      'repeat': recurrence,
    });
    if (response.statusCode != 200) {
      throw const ReminderServiceException(
        'The repeat schedule could not be updated.',
      );
    }
  }

  Future<void> setAudience(String id, String audience) async {
    final response = await _post('set_reminder_audience', {
      'reminder': id,
      'new_audience': audience,
      'email_everyone': false,
    });
    if (response.statusCode != 200) {
      throw const ReminderServiceException(
        'Who can see this reminder could not be updated.',
      );
    }
  }

  Future<void> setEmailDelivery(bool enabled) async {
    final response = await _post('set_reminder_email_delivery', {
      'enabled': enabled,
    });
    if (response.statusCode != 200) {
      throw const ReminderServiceException(
        'Email reminder preference could not be saved.',
      );
    }
  }
}
