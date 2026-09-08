import 'dart:convert';
import 'dart:typed_data';

import 'package:familydocuments_flutter/core/auth/auth_service.dart';
import 'package:familydocuments_flutter/core/auth/session_store.dart';
import 'package:familydocuments_flutter/core/home/home_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

class MemoryStore implements SessionStore {
  @override
  Future<void> clear() async {}

  @override
  Future<String?> readRefreshToken() async => null;

  @override
  Future<void> writeRefreshToken(String token) async {}
}

class TokenClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final body = jsonEncode({
      'access_token': _token(),
      'refresh_token': 'refresh',
      'user': {'id': 'u', 'email': 'test@example.com'},
    });
    return http.StreamedResponse(Stream.value(utf8.encode(body)), 200);
  }
}

class RecordingClient extends http.BaseClient {
  RecordingClient(this.response);
  final http.Response response;
  http.BaseRequest? request;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest value) async {
    request = value;
    return http.StreamedResponse(
      Stream.value(utf8.encode(response.body)),
      response.statusCode,
      headers: response.headers,
    );
  }
}

class RoutingClient extends http.BaseClient {
  final List<http.BaseRequest> requests = [];
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request);
    final path = request.url.path;
    final (status, body) = switch (path) {
      '/rest/rpc/create_reminder' => (
        200,
        {
          'id': 'reminder-1',
          'title': 'Doctor appointment',
          'due_at': '2026-09-09',
          'due_time': '14:00:00',
        },
      ),
      '/document-analysis/jobs' => (
        202,
        {'job_id': 'job-1', 'document_id': 'document-1', 'status': 'queued'},
      ),
      '/document-analysis/jobs/job-1' => (
        200,
        {
          'job_id': 'job-1',
          'document_id': 'document-1',
          'status': 'succeeded',
          'result': {
            'title': 'Test invoice',
            'category': 'Documents',
            'tags': ['invoice'],
          },
        },
      ),
      '/rest/rpc/pending_document_analysis_jobs' => (
        200,
        [
          {
            'job_id': 'job-1',
            'document_id': 'document-1',
            'status': 'processing',
          },
        ],
      ),
      '/rest/rpc/dismiss_document_analysis_job' => (
        200,
        {'job_id': 'job-1', 'document_id': 'document-1', 'status': 'dismissed'},
      ),
      _ => (404, {'error': 'not_found'}),
    };
    return http.StreamedResponse(
      Stream.value(utf8.encode(jsonEncode(body))),
      status,
    );
  }
}

class FailureClient extends http.BaseClient {
  FailureClient(this.status, this.body);
  final int status;
  final Map<String, dynamic> body;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async =>
      http.StreamedResponse(
        Stream.value(utf8.encode(jsonEncode(body))),
        status,
      );
}

String _token() {
  final expiry =
      DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch ~/
      1000;
  final payload = base64Url
      .encode(utf8.encode(jsonEncode({'exp': expiry})))
      .replaceAll('=', '');
  return 'x.$payload.x';
}

Future<AuthService> signedInAuth() async {
  final auth = AuthService(client: TokenClient(), store: MemoryStore());
  await auth.signIn('test@example.com', 'password');
  return auth;
}

void main() {
  test(
    'search sends the existing endpoint and renders source documents',
    () async {
      final client = RecordingClient(
        http.Response(
          jsonEncode({
            'answer': 'I found a document.',
            'sources': [
              {
                'document_title': 'Passport',
                'category_name': 'Travel',
                'critical_date': '2028-03-14',
              },
            ],
          }),
          200,
        ),
      );
      final service = HomeService(await signedInAuth(), client: client);

      final result = await service.search('Find my passport');

      expect(client.request!.url.path, '/search/ask');
      expect(jsonDecode((client.request! as http.Request).body), {
        'query': 'Find my passport',
      });
      expect(client.request!.headers['authorization'], startsWith('Bearer '));
      expect(result.documents.single.title, 'Passport');
      expect(result.documents.single.collection, 'Travel');
    },
  );

  test(
    'standalone reminder sends structured date, time and timezone',
    () async {
      final client = RoutingClient();
      final service = HomeService(await signedInAuth(), client: client);
      final reminder = await service.createReminder(
        title: 'Doctor appointment',
        dueDate: '2026-09-09',
        dueTime: '14:00:00',
        requestId: 'request-12345',
      );
      final request = client.requests.single as http.Request;
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      expect(request.url.path, '/rest/rpc/create_reminder');
      expect(body['related_document'], isNull);
      expect(body['due_timezone'], 'Pacific/Auckland');
      expect(reminder.id, 'reminder-1');
    },
  );

  test('standalone reminder API errors stay user-safe', () async {
    final service = HomeService(
      await signedInAuth(),
      client: FailureClient(422, {'message': 'database details'}),
    );
    expect(
      () => service.createReminder(
        title: 'Doctor appointment',
        dueDate: '2026-09-09',
        requestId: 'request-12345',
      ),
      throwsA(
        isA<HomeServiceException>().having(
          (value) => value.message,
          'message',
          'Your reminder could not be added. Try again.',
        ),
      ),
    );
  });

  test('failed OCR status exposes only safe retry state', () async {
    final service = HomeService(
      await signedInAuth(),
      client: FailureClient(200, {
        'job_id': 'job-1',
        'document_id': 'document-1',
        'status': 'failed',
        'failure': 'This document could not be read.',
        'retry_allowed': true,
      }),
    );
    final job = await service.analysisJob('job-1');
    expect(job.terminal, isTrue);
    expect(job.retryAllowed, isTrue);
    expect(job.failure, 'This document could not be read.');
  });

  test('upload is submitted once to the asynchronous job API', () async {
    final client = RoutingClient();
    final service = HomeService(await signedInAuth(), client: client);
    final job = await service.submitAnalysisJob(
      name: 'bill.pdf',
      mimeType: 'application/pdf',
      bytes: Uint8List.fromList([1, 2, 3]),
      invoice: true,
      idempotencyKey: 'request-12345',
    );
    final request = client.requests.single as http.Request;
    final body = jsonDecode(request.body) as Map<String, dynamic>;
    expect(request.url.path, '/document-analysis/jobs');
    expect(body['mode'], 'invoice');
    expect(body['idempotency_key'], 'request-12345');
    expect(job.status, 'queued');
  });

  test('polling returns the real completed OCR result', () async {
    final client = RoutingClient();
    final service = HomeService(await signedInAuth(), client: client);
    final job = await service.analysisJob('job-1');
    expect(job.terminal, isTrue);
    expect(job.result?.title, 'Test invoice');
  });

  test('pending jobs can be restored from backend state', () async {
    final client = RoutingClient();
    final service = HomeService(await signedInAuth(), client: client);
    final jobs = await service.pendingAnalysisJobs();
    expect(jobs.single.status, 'processing');
  });

  test(
    'failed analysis can be durably dismissed without deleting it',
    () async {
      final client = RoutingClient();
      final service = HomeService(await signedInAuth(), client: client);
      await service.dismissAnalysisJob('job-1');
      final request = client.requests.single as http.Request;
      expect(request.url.path, '/rest/rpc/dismiss_document_analysis_job');
      expect(jsonDecode(request.body), {'job': 'job-1'});
    },
  );

  test('search returns a clear empty result', () async {
    final service = HomeService(
      await signedInAuth(),
      client: RecordingClient(
        http.Response(
          jsonEncode({'answer': 'No matches.', 'sources': []}),
          200,
        ),
      ),
    );

    final result = await service.search('not a document');

    expect(result.documents, isEmpty);
    expect(result.answer, 'No matches.');
  });

  test(
    'upload analysis sends selected Web bytes with MIME type and SHA-256',
    () async {
      final client = RecordingClient(
        http.Response(
          jsonEncode({
            'status': 'saved',
            'title': 'Test Travel Insurance',
            'category': 'Travel',
            'tags': ['insurance', 'test'],
            'pages': 1,
          }),
          200,
        ),
      );
      final service = HomeService(await signedInAuth(), client: client);

      final result = await service.analyseUpload(
        name: 'test.pdf',
        mimeType: 'application/pdf',
        bytes: Uint8List.fromList([1, 2, 3]),
      );

      final body = jsonDecode(
        (client.request! as http.Request).body,
      ) as Map<String, dynamic>;
      expect(client.request!.url.path, '/documents/analyse');
      expect(body['file_name'], 'test.pdf');
      expect(body['mime_type'], 'application/pdf');
      expect(body['content_base64'], 'AQID');
      expect(body['sha256'], hasLength(64));
      expect(result.title, 'Test Travel Insurance');
      expect(result.category, 'Travel');
      expect(result.pageCount, 1);
    },
  );

  test(
    'upload analysis reports backend failures without a false success',
    () async {
      final service = HomeService(
        await signedInAuth(),
        client: RecordingClient(
          http.Response(
            jsonEncode({'error': 'document_could_not_be_read'}),
            422,
          ),
        ),
      );

      expect(
        () => service.analyseUpload(
          name: 'blank.pdf',
          mimeType: 'application/pdf',
          bytes: Uint8List.fromList([1]),
        ),
        throwsA(isA<HomeServiceException>()),
      );
    },
  );
}
