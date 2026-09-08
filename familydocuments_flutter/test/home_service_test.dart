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
