import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../../core/auth/auth_service.dart';
import '../models/inbox_models.dart';

class InboxServiceException implements Exception {
  const InboxServiceException(this.message, {this.accessRevoked = false});
  final String message;
  final bool accessRevoked;
}

class InboxService {
  InboxService(
    this._auth, {
    http.Client? client,
    Duration requestTimeout = const Duration(seconds: 10),
    Duration retryDelay = const Duration(milliseconds: 300),
  }) : _client = client ?? http.Client(),
       _requestTimeout = requestTimeout,
       _retryDelay = retryDelay;
  final AuthService _auth;
  final http.Client _client;
  final Duration _requestTimeout;
  final Duration _retryDelay;

  Future<http.Response> _post(
    String path,
    Map<String, dynamic> body, {
    bool retryTransientFailure = false,
    Duration? timeout,
  }) async {
    Future<http.Response> send() async => _client
        .post(
          Uri.parse('$familyDocumentsApiBaseUrl$path'),
          headers: {
            'authorization': 'Bearer ${await _auth.validAccessToken()}',
            'content-type': 'application/json',
          },
          body: jsonEncode(body),
        )
        .timeout(timeout ?? _requestTimeout);
    for (var attempt = 0; ; attempt++) {
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
        if (retryTransientFailure && attempt == 0) {
          await Future<void>.delayed(_retryDelay);
          continue;
        }
        throw const InboxServiceException(
          'Inbox could not be reached. Try again.',
        );
      }
    }
  }

  Future<InboxData> load({
    String query = '',
    InboxFilter filter = InboxFilter.all,
    int limit = 30,
    int offset = 0,
  }) async {
    final telegramOnly = filter == InboxFilter.telegram;
    final effectiveFilter = telegramOnly ? InboxFilter.all : filter;
    final response = await _post('/rest/rpc/inbox_workspace', {
      'search_query': query.trim().isEmpty ? null : query.trim(),
      'state_filter': effectiveFilter.name,
      'result_limit': limit,
      'result_offset': offset,
    }, retryTransientFailure: true);
    if (response.statusCode != 200) {
      throw const InboxServiceException(
        'Inbox could not be loaded. Try again.',
      );
    }
    try {
      final email = InboxData.fromJson(jsonDecode(response.body) as Map);
      if (filter == InboxFilter.links) {
        return email;
      }
      http.Response telegramResponse;
      try {
        // Telegram is an enhancement to the main Inbox. It must not leave all
        // email items behind a spinner while its separate service is slow.
        telegramResponse = await _post('/rest/rpc/telegram_inbox_workspace', {
          'search_query': query.trim().isEmpty ? null : query.trim(),
          'state_filter': effectiveFilter.name,
          'result_limit': limit,
          'result_offset': offset,
        }, timeout: const Duration(seconds: 6));
      } on InboxServiceException {
        if (telegramOnly) rethrow;
        return email;
      }
      if (telegramResponse.statusCode != 200) {
        if (telegramOnly) {
          throw const InboxServiceException(
            'Inbox could not be loaded. Try again.',
          );
        }
        return email;
      }
      final telegram = InboxData.fromJson(
        jsonDecode(telegramResponse.body) as Map,
      );
      if (telegramOnly) {
        return InboxData(
          canEdit: telegram.canEdit,
          total: telegram.total,
          items: telegram.items,
          categories: email.categories,
          tags: email.tags,
          linkCategories: email.linkCategories,
        );
      }
      final items = [...email.items, ...telegram.items]
        ..sort((a, b) => b.receivedAt.compareTo(a.receivedAt));
      return InboxData(
        canEdit: email.canEdit,
        total: email.total + telegram.total,
        items: items.take(limit).toList(),
        categories: email.categories,
        tags: email.tags,
        linkCategories: email.linkCategories,
      );
    } catch (_) {
      throw const InboxServiceException(
        'Inbox returned an unexpected response.',
      );
    }
  }

  Future<InboxMessage> detail(String id) async {
    var response = await _post('/rest/rpc/inbox_message_detail', {
      'message': id,
    });
    if ({403, 404}.contains(response.statusCode)) {
      response = await _post('/rest/rpc/telegram_inbox_message_detail', {
        'message': id,
      });
    }
    if ({401, 403, 404}.contains(response.statusCode)) {
      throw const InboxServiceException(
        'You no longer have access to this item.',
        accessRevoked: true,
      );
    }
    if (response.statusCode != 200) {
      throw const InboxServiceException('This message could not be opened.');
    }
    return InboxMessage.fromJson(jsonDecode(response.body) as Map);
  }

  Future<void> setReviewState(InboxMessage message, String state) async {
    var response = await _post('/rest/rpc/set_inbox_review_state', {
      'message': message.id,
      'new_state': state,
      'expected_updated_at': message.updatedAt.toUtc().toIso8601String(),
    });
    if ({403, 404}.contains(response.statusCode)) {
      response = await _post('/rest/rpc/set_telegram_inbox_review_state', {
        'message': message.id,
        'new_state': state,
        'expected_updated_at': message.updatedAt.toUtc().toIso8601String(),
      });
    }
    if ({401, 403, 404}.contains(response.statusCode)) {
      throw const InboxServiceException(
        'You cannot change this message.',
        accessRevoked: true,
      );
    }
    if (response.statusCode != 200) {
      throw const InboxServiceException(
        'The review state could not be changed. Try again.',
      );
    }
  }

  Future<InboxActionResult> saveAttachment({
    required String messageId,
    required String attachmentId,
    required String categoryId,
    required List<String> tags,
    required bool requestOcr,
    required String requestId,
  }) async {
    final normalized = tags
        .map((x) => x.trim().toLowerCase())
        .where((x) => x.isNotEmpty)
        .toSet()
        .toList();
    final response = await _post('/drive/inbox-attachment', {
      'message_id': messageId,
      'attachment_id': attachmentId,
      'category_id': categoryId,
      'tags': normalized,
      'request_id': requestId,
      'request_ocr': requestOcr,
    });
    if ({401, 403, 404}.contains(response.statusCode)) {
      throw const InboxServiceException(
        'This attachment is no longer available.',
        accessRevoked: true,
      );
    }
    if (response.statusCode != 200) {
      throw const InboxServiceException(
        'The attachment could not be saved. Try again.',
      );
    }
    final body = jsonDecode(response.body) as Map;
    return InboxActionResult(
      documentId: body['document_id']?.toString(),
      jobId: body['job_id']?.toString(),
      duplicate: body['duplicate'] == true,
    );
  }

  Future<void> createReminder({
    required String messageId,
    required String title,
    required String date,
    String? time,
    required String recurrence,
    required String requestId,
  }) async {
    final response = await _post('/rest/rpc/inbox_create_reminder', {
      'message': messageId,
      'reminder_title': title.trim(),
      'due_date': date,
      'due_time_value': time,
      'repeat': recurrence,
      'request_id': requestId,
    });
    if (response.statusCode != 200) {
      throw const InboxServiceException(
        'The reminder could not be added. Check the date and time.',
      );
    }
  }

  Future<void> saveLink({
    required String messageId,
    required String url,
    required String title,
    required String categoryId,
    required String requestId,
  }) async {
    final response = await _post('/rest/rpc/inbox_save_link', {
      'message': messageId,
      'link_url': url,
      'link_title': title.trim(),
      'category': categoryId,
      'request_id': requestId,
    });
    if (response.statusCode != 200) {
      throw const InboxServiceException(
        'The link could not be saved. Try again.',
      );
    }
  }

  Future<InboxCategory> createCategory(String name) async {
    final response = await _post('/rest/rpc/create_category', {
      'category_name': name.trim(),
    });
    if (response.statusCode != 200) {
      throw const InboxServiceException(
        'That category could not be created. Choose another name.',
      );
    }
    return InboxCategory.fromJson(jsonDecode(response.body) as Map);
  }

  Future<InboxCategory> createLinkCategory(String name) async {
    final response = await _post('/rest/rpc/create_saved_link_category', {
      'category_name': name.trim(),
    });
    if (response.statusCode != 200) {
      throw const InboxServiceException(
        'That link category could not be created. Choose another name.',
      );
    }
    return InboxCategory.fromJson(jsonDecode(response.body) as Map);
  }
}
