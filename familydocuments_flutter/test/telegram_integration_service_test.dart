import 'dart:convert';

import 'package:familydocuments_flutter/core/auth/auth_service.dart';
import 'package:familydocuments_flutter/features/settings/telegram/telegram_integration_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class _TokenAuth extends AuthService {
  @override
  Future<String> validAccessToken() async => 'fake-access-token';

  @override
  Future<Session> refresh([String? token]) => throw UnimplementedError();
}

void main() {
  final states = <String, TelegramConnectionState>{
    'not_connected': TelegramConnectionState.notConnected,
    'link_pending': TelegramConnectionState.linkPending,
    'connected': TelegramConnectionState.connected,
    'disconnected': TelegramConnectionState.disconnected,
    'membership_revoked': TelegramConnectionState.membershipRevoked,
  };

  for (final entry in states.entries) {
    test('decodes exact ${entry.key} Telegram status', () async {
      final service = TelegramIntegrationService(
        _TokenAuth(),
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'state': entry.key,
              'selection_required': false,
              'family_id': '11111111-1111-4111-8111-111111111111',
              'family_name': 'Test Family',
              'display_name': null,
              'username': null,
              'connected_at': null,
              'link_expires_at': entry.key == 'link_pending'
                  ? '2027-01-20T01:00:00Z'
                  : null,
            }),
            200,
          ),
        ),
      );
      final status = await service.status();
      expect(status.state, entry.value);
      expect(status.displayName, isNull);
      expect(status.username, isNull);
      expect(
        status.linkExpiresAt,
        entry.key == 'link_pending' ? isNotNull : isNull,
      );
    });
  }

  test('rejects an unknown Telegram status safely', () async {
    final service = TelegramIntegrationService(
      _TokenAuth(),
      client: MockClient(
        (_) async => http.Response(
          '{"state":"unexpected","selection_required":false}',
          200,
        ),
      ),
    );
    await expectLater(
      service.status(),
      throwsA(isA<TelegramIntegrationException>()),
    );
  });
}
