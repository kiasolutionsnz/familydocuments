import 'dart:convert';

import 'package:familydocuments_flutter/core/auth/auth_service.dart';
import 'package:familydocuments_flutter/features/timeline/data/timeline_service.dart';
import 'package:familydocuments_flutter/features/timeline/models/timeline_item.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

class TimelineAuth extends AuthService {
  int refreshes = 0;
  @override
  Future<String> validAccessToken() async => 'timeline-token';
  @override
  Future<Session> refresh([String? token]) async {
    refreshes++;
    return Session(
      accessToken: 'refreshed-token',
      refreshToken: 'refresh',
      email: 'timeline@example.test',
      userId: 'user-1',
    );
  }
}

class TimelineClient extends http.BaseClient {
  TimelineClient(this.responses);
  final List<http.Response> responses;
  final List<http.Request> requests = [];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request as http.Request);
    final response = responses.removeAt(0);
    return http.StreamedResponse(
      Stream.value(utf8.encode(response.body)),
      response.statusCode,
    );
  }
}

void main() {
  test('parses mixed Timeline metadata and its next cursor', () async {
    final client = TimelineClient([
      http.Response(
        jsonEncode({
          'items': [
            {
              'id': 'document-1',
              'event_key': 'document:1',
              'kind': 'document',
              'event_type': 'document_saved',
              'title': 'Passport saved',
              'context': 'Travel',
              'occurred_at': '2026-09-09T02:00:00Z',
              'category': 'Travel',
              'tags': ['passport'],
            },
            {
              'id': 'link-1',
              'event_key': 'link:1',
              'kind': 'link',
              'event_type': 'saved_link_added',
              'title': 'Recipe saved',
              'occurred_at': '2026-09-09T01:00:00Z',
              'url': 'https://example.test/recipe',
            },
          ],
          'has_more': true,
          'next_cursor': {
            'occurred_at': '2026-09-09T01:00:00Z',
            'event_key': 'link:1',
          },
        }),
        200,
      ),
    ]);
    final result = await TimelineService(TimelineAuth(), client: client).load();
    expect(result.items, hasLength(2));
    expect(result.items.first.kind, TimelineItemKind.document);
    expect(result.items.first.tags, ['passport']);
    expect(result.items.last.kind, TimelineItemKind.link);
    expect(result.hasMore, isTrue);
    expect(result.nextCursor?.key, 'link:1');
    expect(client.requests.single.url.path, '/rest/rpc/family_timeline');
    expect(
      client.requests.single.headers['authorization'],
      'Bearer timeline-token',
    );
  });

  test(
    'sends search and stable pagination cursor without a Family id',
    () async {
      final client = TimelineClient([
        http.Response(jsonEncode({'items': [], 'has_more': false}), 200),
      ]);
      await TimelineService(TimelineAuth(), client: client).load(
        query: 'passport',
        cursor: TimelineCursor(
          occurredAt: DateTime.utc(2026, 9, 9, 1),
          key: 'document:1',
        ),
        limit: 20,
      );
      final body =
          jsonDecode(client.requests.single.body) as Map<String, dynamic>;
      expect(body['search_query'], 'passport');
      expect(body['before_key'], 'document:1');
      expect(body['result_limit'], 20);
      expect(body.containsKey('household_id'), isFalse);
    },
  );

  test(
    'retries one unauthorized Timeline request after session refresh',
    () async {
      final auth = TimelineAuth();
      final client = TimelineClient([
        http.Response('{}', 401),
        http.Response(jsonEncode({'items': [], 'has_more': false}), 200),
      ]);
      await TimelineService(auth, client: client).load();
      expect(auth.refreshes, 1);
      expect(client.requests, hasLength(2));
    },
  );
}
