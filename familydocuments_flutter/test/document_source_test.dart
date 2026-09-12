import 'dart:convert';

import 'package:familydocuments_flutter/core/auth/auth_service.dart';
import 'package:familydocuments_flutter/features/library/data/library_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class _Auth extends AuthService {
  @override
  Future<String> validAccessToken() async => 'synthetic-access';
}

void main() {
  test('local source returns original bytes without OCR requests', () async {
    final requests = <String>[];
    final service = LibraryService(
      _Auth(),
      client: MockClient((request) async {
        requests.add(request.url.path);
        expect(request.headers['authorization'], 'Bearer synthetic-access');
        return http.Response(
          jsonEncode({
            'file_name': 'synthetic.pdf',
            'mime_type': 'application/pdf',
            'content_base64': base64Encode([37, 80, 68, 70, 45]),
          }),
          200,
        );
      }),
    );
    final source = await service.source('synthetic-id');
    expect(source.bytes, [37, 80, 68, 70, 45]);
    expect(requests, ['/rest/rpc/document_preview_source']);
  });

  test('PostgreSQL line-wrapped base64 opens the original file', () async {
    final original = List<int>.generate(100, (index) => index);
    final encoded = base64Encode(original);
    final wrapped = '${encoded.substring(0, 76)}\n${encoded.substring(76)}';
    final service = LibraryService(
      _Auth(),
      client: MockClient(
        (_) async => http.Response(
          jsonEncode({
            'file_name': 'synthetic.pdf',
            'mime_type': 'application/pdf',
            'content_base64': wrapped,
          }),
          200,
        ),
      ),
    );

    expect((await service.source('synthetic-id')).bytes, original);
  });

  test('Drive source uses the existing authorised gateway path', () async {
    final requests = <String>[];
    final service = LibraryService(
      _Auth(),
      client: MockClient((request) async {
        requests.add(request.url.path);
        if (request.url.path == '/rest/rpc/document_preview_source') {
          return http.Response('{"provider":"google_drive"}', 200);
        }
        return http.Response(
          jsonEncode({
            'file_name': 'drive.png',
            'mime_type': 'image/png',
            'content_base64': base64Encode([1, 2, 3]),
          }),
          200,
        );
      }),
    );
    final source = await service.source('drive-id');
    expect(source.bytes, [1, 2, 3]);
    expect(requests, ['/rest/rpc/document_preview_source', '/drive/open']);
  });

  test('missing, revoked, disconnected and temporary states differ', () async {
    for (final (status, body, revoked, disconnected, temporary) in [
      (404, '{}', true, false, false),
      (200, '{"status":"file_unavailable"}', false, false, false),
      (200, '{"status":"provider_disconnected"}', false, true, false),
      (503, '{}', false, false, true),
    ]) {
      final service = LibraryService(
        _Auth(),
        client: MockClient((request) async => http.Response(body, status)),
      );
      try {
        await service.source('synthetic-id');
        fail('Expected a source error');
      } on LibraryServiceException catch (error) {
        expect(error.accessRevoked, revoked);
        expect(error.providerDisconnected, disconnected);
        expect(error.temporary, temporary);
      }
    }
  });
}
