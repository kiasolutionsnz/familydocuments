import 'dart:typed_data';
import 'dart:math';

import 'package:familydocuments_flutter/core/home/selected_upload.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

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

  test(
    'large photo is converted to an OCR-sized JPEG under server limit',
    () async {
      final photo = img.Image(width: 1400, height: 1400);
      final random = Random(17);
      for (var y = 0; y < photo.height; y++) {
        for (var x = 0; x < photo.width; x++) {
          photo.setPixelRgb(
            x,
            y,
            random.nextInt(256),
            random.nextInt(256),
            random.nextInt(256),
          );
        }
      }
      final original = img.encodePng(photo);
      expect(original.length, greaterThan(maxSelectedUploadBytes));
      final upload = await preparePhotoUpload(
        name: 'camera.png',
        bytes: original,
      );
      expect(upload.optimized, isTrue);
      expect(upload.name, 'camera.jpg');
      expect(upload.mimeType, 'image/jpeg');
      expect(upload.bytes.length, lessThanOrEqualTo(maxSelectedUploadBytes));
      final decoded = img.decodeJpg(upload.bytes)!;
      expect(decoded.width, 1400);
      expect(decoded.height, 1400);
    },
  );
}
