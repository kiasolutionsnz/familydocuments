import 'dart:typed_data';

import 'package:familydocuments_flutter/core/home/selected_upload.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Web-style in-memory PDF needs no filesystem path', () {
    final upload = prepareSelectedUpload(
      name: 'synthetic-bill.pdf',
      bytes: Uint8List.fromList('%PDF-1.4 synthetic'.codeUnits),
    );
    expect(upload.mimeType, 'application/pdf');
    expect(upload.bytes, isNotEmpty);
  });

  test('missing bytes has a distinct safe error', () {
    expect(
      () => prepareSelectedUpload(name: 'bill.pdf', bytes: null),
      throwsA(
        isA<SelectedUploadException>().having(
          (error) => error.message,
          'message',
          contains('could not be read'),
        ),
      ),
    );
  });

  test('unsupported type has a distinct safe error', () {
    expect(
      () => prepareSelectedUpload(
        name: 'notes.txt',
        bytes: Uint8List.fromList('notes'.codeUnits),
      ),
      throwsA(
        isA<SelectedUploadException>().having(
          (error) => error.message,
          'message',
          contains('isn’t supported'),
        ),
      ),
    );
  });

  test('oversized file has a distinct safe error', () {
    final bytes = Uint8List(maxSelectedUploadBytes + 1)
      ..setRange(0, 5, '%PDF-'.codeUnits);
    expect(
      () => prepareSelectedUpload(name: 'large.pdf', bytes: bytes),
      throwsA(
        isA<SelectedUploadException>().having(
          (error) => error.message,
          'message',
          contains('too large'),
        ),
      ),
    );
  });

  test('extension and actual type must agree', () {
    expect(
      () => prepareSelectedUpload(
        name: 'not-really.pdf',
        bytes: Uint8List.fromList([0x89, 0x50, 0x4e, 0x47]),
      ),
      throwsA(isA<SelectedUploadException>()),
    );
  });
}
