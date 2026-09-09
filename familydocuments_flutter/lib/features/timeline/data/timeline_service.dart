import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../../core/auth/auth_service.dart';
import '../models/timeline_item.dart';

class TimelineServiceException implements Exception {
  const TimelineServiceException(this.message);
  final String message;
}

class TimelineService {
  TimelineService(this._auth, {http.Client? client})
    : _client = client ?? http.Client();

  final AuthService _auth;
  final http.Client _client;

  Future<TimelinePageData> load({
    String query = '',
    TimelineCursor? cursor,
    int limit = 40,
  }) async {
    Future<http.Response> send() async {
      final token = await _auth.validAccessToken();
      return _client.post(
        Uri.parse('$familyDocumentsApiBaseUrl/rest/rpc/family_timeline'),
        headers: {
          'authorization': 'Bearer $token',
          'content-type': 'application/json',
        },
        body: jsonEncode({
          'before_time': cursor?.occurredAt.toUtc().toIso8601String(),
          'before_key': cursor?.key,
          'search_query': query.trim().isEmpty ? null : query.trim(),
          'result_limit': limit,
        }),
      );
    }

    http.Response response;
    try {
      response = await send();
      if (response.statusCode == 401) {
        await _auth.refresh();
        response = await send();
      }
    } on AuthException {
      rethrow;
    } catch (_) {
      throw const TimelineServiceException(
        'Timeline could not be reached. Try again.',
      );
    }
    if (response.statusCode != 200) {
      throw const TimelineServiceException(
        'Timeline could not be loaded. Try again.',
      );
    }
    try {
      final payload = jsonDecode(response.body) as Map<String, dynamic>;
      final items =
          (payload['items'] as List?)
              ?.whereType<Map>()
              .map(
                (item) =>
                    TimelineItem.fromJson(Map<String, dynamic>.from(item)),
              )
              .toList() ??
          const <TimelineItem>[];
      final cursorValue = payload['next_cursor'];
      TimelineCursor? nextCursor;
      if (cursorValue is Map) {
        final time = DateTime.tryParse(
          cursorValue['occurred_at']?.toString() ?? '',
        );
        final key = cursorValue['event_key']?.toString();
        if (time != null && key != null && key.isNotEmpty) {
          nextCursor = TimelineCursor(occurredAt: time, key: key);
        }
      }
      return TimelinePageData(
        items: items,
        hasMore: payload['has_more'] == true,
        nextCursor: nextCursor,
      );
    } catch (_) {
      throw const TimelineServiceException(
        'Timeline returned an unexpected response.',
      );
    }
  }
}
