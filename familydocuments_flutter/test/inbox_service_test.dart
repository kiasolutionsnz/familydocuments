import 'dart:convert';

import 'package:familydocuments_flutter/core/auth/auth_service.dart';
import 'package:familydocuments_flutter/features/inbox/data/inbox_service.dart';
import 'package:familydocuments_flutter/features/inbox/models/inbox_models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

class _Auth extends AuthService {
  @override
  Future<String> validAccessToken() async => 'fake-access';
}

class _Client extends http.BaseClient {
  final requests = <http.Request>[];
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final value = request as http.Request;
    requests.add(value);
    final path = value.url.path;
    final body = switch (path) {
      '/rest/rpc/inbox_workspace' => {
        'can_edit': true,
        'total': 1,
        'items': [
          {
            'id': 'message-1',
            'sender': 'sender@example.test',
            'subject': 'Invoice',
            'received_at': '2027-01-20T02:00:00Z',
            'source': 'Email',
            'preview': 'Please review',
            'attachment_count': 1,
            'link_count': 1,
            'review_state': 'unreviewed',
            'updated_at': '2027-01-20T02:00:00Z',
            'actions': [],
          },
        ],
        'categories': [
          {'id': 'finance', 'name': 'Finance'},
        ],
        'tags': ['invoice'],
        'link_categories': [
          {'id': 'research', 'name': 'Research'},
        ],
      },
      '/rest/rpc/inbox_message_detail' => {
        'id': 'message-1',
        'sender': 'sender@example.test',
        'recipients': ['family@example.test'],
        'subject': 'Invoice',
        'received_at': '2027-01-20T02:00:00Z',
        'source': 'Email',
        'body_text': 'Safe text',
        'review_state': 'unreviewed',
        'updated_at': '2027-01-20T02:00:00Z',
        'can_edit': true,
        'attachments': [],
        'links': [],
        'actions': [],
      },
      '/rest/rpc/inbox_save_attachment' => {
        'document_id': 'document-1',
        'job_id': 'job-1',
        'duplicate': false,
      },
      _ => {},
    };
    return http.StreamedResponse(
      Stream.value(utf8.encode(jsonEncode(body))),
      200,
    );
  }
}

void main() {
  test('loads predictable Inbox query and filter parameters', () async {
    final client = _Client();
    final service = InboxService(_Auth(), client: client);
    final data = await service.load(
      query: '  Invoice  ',
      filter: InboxFilter.attachments,
      offset: 30,
    );
    expect(data.items.single.subject, 'Invoice');
    final body = jsonDecode(client.requests.single.body) as Map;
    expect(body['search_query'], 'Invoice');
    expect(body['state_filter'], 'attachments');
    expect(body['result_offset'], 30);
  });

  test('loads safe message detail', () async {
    final service = InboxService(_Auth(), client: _Client());
    final detail = await service.detail('message-1');
    expect(detail.bodyText, 'Safe text');
    expect(detail.recipients, ['family@example.test']);
  });

  test(
    'attachment save normalises duplicate tags and requests OCR once',
    () async {
      final client = _Client();
      final service = InboxService(_Auth(), client: client);
      final result = await service.saveAttachment(
        messageId: 'message-1',
        attachmentId: 'attachment-1',
        categoryId: 'finance',
        tags: const [' Invoice ', 'invoice', 'Family'],
        requestOcr: true,
        requestId: 'request-12345',
      );
      expect(result.jobId, 'job-1');
      final body = jsonDecode(client.requests.single.body) as Map;
      expect(body['selected_tags'], ['invoice', 'family']);
      expect(body['request_ocr'], isTrue);
      expect(body['request_id'], 'request-12345');
    },
  );

  test('review, reminder and link actions use focused RPCs', () async {
    final client = _Client();
    final service = InboxService(_Auth(), client: client);
    final detail = await service.detail('message-1');
    await service.setReviewState(detail, 'reviewed');
    await service.createReminder(
      messageId: 'message-1',
      title: 'Review invoice',
      date: '2027-01-20',
      recurrence: 'none',
      requestId: 'reminder-12345',
    );
    await service.saveLink(
      messageId: 'message-1',
      url: 'https://example.test',
      title: 'Example',
      categoryId: 'research',
      requestId: 'link-12345',
    );
    expect(
      client.requests.map((x) => x.url.path),
      containsAll([
        '/rest/rpc/set_inbox_review_state',
        '/rest/rpc/inbox_create_reminder',
        '/rest/rpc/inbox_save_link',
      ]),
    );
  });
}
