import 'dart:convert';

import 'package:familydocuments_flutter/core/auth/auth_service.dart';
import 'package:familydocuments_flutter/features/conversation/data/conversation_service.dart';
import 'package:familydocuments_flutter/features/conversation/models/conversation_models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

class FakeAuth extends AuthService {
  int refreshes = 0;

  @override
  Future<String> validAccessToken() async => 'synthetic-access-token';

  @override
  Future<Session> refresh([String? token]) async {
    refreshes++;
    return Session(
      accessToken: 'synthetic-access-token',
      refreshToken: 'synthetic-refresh-token',
      email: 'owner@example.test',
      userId: 'owner',
    );
  }
}

class FakeClient extends http.BaseClient {
  FakeClient(this.handler);
  final Future<http.Response> Function(http.BaseRequest request, String body)
  handler;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final body = request is http.Request ? request.body : '';
    final response = await handler(request, body);
    return http.StreamedResponse(
      Stream.value(response.bodyBytes),
      response.statusCode,
      headers: response.headers,
      request: request,
    );
  }
}

void main() {
  test(
    'restore loads bounded messages and a structured confirmation',
    () async {
      final auth = FakeAuth();
      final service = ConversationService(
        auth,
        client: FakeClient((request, body) async {
          expect(
            request.url.path,
            endsWith('/rest/rpc/conversation_workspace'),
          );
          expect(
            request.headers['authorization'],
            'Bearer synthetic-access-token',
          );
          return http.Response(
            jsonEncode({
              'conversation': {'id': 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'},
              'messages': [
                {
                  'id': 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
                  'client_message_id': 'message-12345678',
                  'role': 'user',
                  'kind': 'text',
                  'content': 'Find my passport',
                  'data': <String, dynamic>{},
                  'created_at': '2027-01-01T00:00:00Z',
                },
              ],
              'pending_confirmation': {
                'id': '11111111-1111-4111-8111-111111111111',
                'summary': 'Dismiss this item?',
                'target_label': 'Synthetic message',
                'expires_at': DateTime.now()
                    .add(const Duration(minutes: 5))
                    .toUtc()
                    .toIso8601String(),
              },
            }),
            200,
          );
        }),
      );

      final snapshot = await service.restore();
      expect(snapshot.messages.single.content, 'Find my passport');
      expect(snapshot.pendingConfirmation!.summary, 'Dismiss this item?');
      expect(snapshot.pendingConfirmation!.targetLabel, 'Synthetic message');
    },
  );

  test(
    'model interpretation receives bounded references but no credentials',
    () async {
      final auth = FakeAuth();
      final service = ConversationService(
        auth,
        client: FakeClient((request, body) async {
          final payload = jsonDecode(body) as Map<String, dynamic>;
          expect(request.url.path, '/conversation/interpret');
          expect(body, isNot(contains('synthetic-refresh-token')));
          expect((payload['context'] as Map)['references'], hasLength(8));
          return http.Response(
            jsonEncode({
              'action': {
                'id': 'proposal-12345678',
                'type': 'search_family_content',
                'version': 1,
                'parameters': {'query': 'passport'},
              },
            }),
            200,
          );
        }),
      );
      final references = List.generate(
        12,
        (index) => ConversationReference(
          type: 'document',
          id: '00000000-0000-4000-8000-${index.toString().padLeft(12, '0')}',
          label: 'Document $index',
        ),
      );
      final action = await service.interpret(
        message: 'Find it',
        references: references,
        hasAttachment: false,
      );
      expect(action.type, ConversationActionType.searchFamilyContent);
    },
  );

  test('401 retries once with refreshed authentication', () async {
    final auth = FakeAuth();
    var calls = 0;
    final service = ConversationService(
      auth,
      client: FakeClient((request, body) async {
        calls++;
        if (calls == 1) return http.Response('{}', 401);
        return http.Response(
          jsonEncode({'id': 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'}),
          200,
        );
      }),
    );
    expect(await service.start('conversation-request-0001'), isNotEmpty);
    expect(auth.refreshes, 1);
    expect(calls, 2);
  });

  test(
    'lost action response retains the signed model proposal for retry',
    () async {
      final auth = FakeAuth();
      var actionCalls = 0;
      final submittedTokens = <String?>[];
      final service = ConversationService(
        auth,
        client: FakeClient((request, body) async {
          if (request.url.path == '/conversation/interpret') {
            return http.Response(
              jsonEncode({
                'action': {
                  'id': 'proposal-12345678',
                  'type': 'save_link',
                  'version': 1,
                  'parameters': {
                    'url': 'https://familydocuments.app/',
                    'category_name': 'Travel',
                  },
                },
                'proposal_token': 'synthetic-signed-proposal',
              }),
              200,
            );
          }
          final payload = jsonDecode(body) as Map<String, dynamic>;
          submittedTokens.add(payload['proposal_token']?.toString());
          actionCalls++;
          if (actionCalls == 1) return http.Response('{}', 502);
          return http.Response(
            jsonEncode({
              'execution_id': 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee',
              'state': 'awaiting_confirmation',
              'action_type': 'save_link',
              'result': <String, dynamic>{},
            }),
            200,
          );
        }),
      );
      final action = await service.interpret(
        message: 'Save the link in Travel',
        references: const [],
        hasAttachment: false,
      );
      await expectLater(
        service.submitAction('conversation', action, action.id),
        throwsA(isA<ConversationServiceException>()),
      );
      await service.submitAction('conversation', action, action.id);
      expect(submittedTokens, [
        'synthetic-signed-proposal',
        'synthetic-signed-proposal',
      ]);
    },
  );
}
