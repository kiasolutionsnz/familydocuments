import 'dart:convert';

import 'package:familydocuments_flutter/core/auth/auth_service.dart';
import 'package:familydocuments_flutter/features/reminders/data/reminder_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

class _Auth extends AuthService {
  @override
  Future<String> validAccessToken() async => 'test-token';
}

class _Client extends http.BaseClient {
  final paths = <String>[];
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final path = request.url.path;
    paths.add(path);
    final response = switch (path) {
      '/rest/rpc/reminder_dashboard' => http.Response(
        jsonEncode({
          'items': [
            {
              'id': 'reminder-1',
              'title': 'Insurance renewal',
              'due_at': '2026-10-01',
              'status': 'upcoming',
              'due_state': 'upcoming',
              'recurrence': 'yearly',
              'audience': 'personal',
            },
          ],
        }),
        200,
      ),
      '/rest/rpc/reminder_delivery_settings' => http.Response('{}', 503),
      '/rest/rpc/set_reminder_recurrence' => http.Response('{}', 200),
      _ => http.Response('{}', 404),
    };
    return http.StreamedResponse(
      Stream.value(response.bodyBytes),
      response.statusCode,
      request: request,
    );
  }
}

class _TransientClient extends _Client {
  var failuresRemaining = 1;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    if (request.url.path == '/rest/rpc/reminder_dashboard' &&
        failuresRemaining > 0) {
      failuresRemaining--;
      return Future<http.StreamedResponse>.error(
        http.ClientException('synthetic transient failure', request.url),
      );
    }
    return super.send(request);
  }
}

void main() {
  test('repeat edits use the standalone-capable endpoint', () async {
    final client = _Client();
    await ReminderService(
      _Auth(),
      client: client,
    ).configure('reminder-1', 'monthly');
    expect(client.paths, ['/rest/rpc/set_reminder_recurrence']);
  });
  test(
    'keeps reminders usable when optional delivery settings are unavailable',
    () async {
      final dashboard = await ReminderService(
        _Auth(),
        client: _Client(),
      ).load();

      expect(dashboard.items.single.title, 'Insurance renewal');
      expect(dashboard.emailEnabled, isTrue);
      expect(dashboard.deliveryHistory, isEmpty);
    },
  );

  test('retries a transient reminder dashboard request once', () async {
    final client = _TransientClient();
    final dashboard = await ReminderService(
      _Auth(),
      client: client,
      retryDelay: Duration.zero,
    ).load();

    expect(dashboard.items.single.title, 'Insurance renewal');
    expect(client.failuresRemaining, 0);
  });
}
