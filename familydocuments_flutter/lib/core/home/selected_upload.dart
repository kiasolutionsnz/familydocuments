import 'dart:typed_data';

import 'package:image/image.dart' as img;

const int maxSelectedUploadBytes = 5 * 1024 * 1024;
const int maxSelectedPhotoBytes = 20 * 1024 * 1024;

class SelectedUploadException implements Exception {
  const SelectedUploadException(this.message);

  final String message;
}

class SelectedUpload {
  const SelectedUpload({
    required this.name,
    required this.bytes,
    required this.mimeType,
    this.optimized = false,
  });

  final String name;
  final Uint8List bytes;
  final String mimeType;
  final bool optimized;
}

/// Keep the existing 5 MB server/OCR limit, while accepting larger camera
/// photos. Never resize below a 2400-pixel long edge or use low JPEG quality:
/// those safeguards favour legible small print over a smaller upload.
Future<SelectedUpload> preparePhotoUpload({
  required String name,
  required Uint8List? bytes,
}) async {
  final mimeType = _mimeTypeForName(name);
  if (bytes == null ||
      bytes.isEmpty ||
      mimeType == null ||
      mimeType == 'application/pdf' ||
      bytes.length <= maxSelectedUploadBytes) {
    return prepareSelectedUpload(name: name, bytes: bytes);
  }
  if (bytes.length > maxSelectedPhotoBytes) {
    throw const SelectedUploadException(
      'That photo is too large. Choose one up to 20 MB.',
    );
  }
  if (!_hasExpectedSignature(bytes, mimeType)) {
    throw const SelectedUploadException(
      'That file’s contents do not match its type. Choose a JPG or PNG.',
    );
  }
  final decoded = img.decodeImage(bytes);
  if (decoded == null || decoded.width * decoded.height > 40000000) {
    throw const SelectedUploadException(
      'That photo could not be safely processed. Choose a smaller photo.',
    );
  }
  final oriented = img.bakeOrientation(decoded);
  final longest = oriented.width > oriented.height
      ? oriented.width
      : oriented.height;
  for (final target in const [3600, 3200, 2800, 2400]) {
    final resized = longest > target
        ? img.copyResize(
            oriented,
            width: oriented.width >= oriented.height ? target : null,
            height: oriented.height > oriented.width ? target : null,
            interpolation: img.Interpolation.cubic,
          )
        : oriented;
    final quality = switch (target) {
      3600 => 92,
      3200 => 90,
      2800 => 88,
      _ => 86,
    };
    final printable = resized.hasAlpha
        ? img.compositeImage(
            img.Image(width: resized.width, height: resized.height)
              ..clear(img.ColorRgb8(255, 255, 255)),
            resized,
          )
        : resized;
    final encoded = img.encodeJpg(printable, quality: quality);
    if (encoded.length <= maxSelectedUploadBytes) {
      final jpgName = name.replaceFirst(RegExp(r'\.[^.]+$'), '.jpg');
      return SelectedUpload(
        name: jpgName,
        bytes: encoded,
        mimeType: 'image/jpeg',
        optimized: true,
      );
    }
  }
  throw const SelectedUploadException(
    'This photo could not be reduced without risking readable text. Try a clearer crop or scan.',
  );
}

SelectedUpload prepareSelectedUpload({
  required String name,
  required Uint8List? bytes,
}) {
  final mimeType = _mimeTypeForName(name);
  if (mimeType == null) {
    throw const SelectedUploadException(
      'That file type isn’t supported. Choose a PDF, JPG or PNG.',
    );
  }
  if (bytes == null || bytes.isEmpty) {
    throw const SelectedUploadException(
      'The selected file could not be read. Choose it again.',
    );
  }
  if (bytes.length > maxSelectedUploadBytes) {
    throw const SelectedUploadException(
      'That file is too large. Choose a file up to 5 MB.',
    );
  }
  if (!_hasExpectedSignature(bytes, mimeType)) {
    throw const SelectedUploadException(
      'That file’s contents do not match its type. Choose a PDF, JPG or PNG.',
    );
  }
  return SelectedUpload(name: name, bytes: bytes, mimeType: mimeType);
}

String? _mimeTypeForName(String name) {
  final extension = name.split('.').last.toLowerCase();
  return switch (extension) {
    'pdf' => 'application/pdf',
    'jpg' || 'jpeg' => 'image/jpeg',
    'png' => 'image/png',
    _ => null,
  };
}

bool _hasExpectedSignature(Uint8List bytes, String mimeType) {
  return switch (mimeType) {
    'application/pdf' =>
      bytes.length >= 5 &&
          bytes[0] == 0x25 &&
          bytes[1] == 0x50 &&
          bytes[2] == 0x44 &&
          bytes[3] == 0x46 &&
          bytes[4] == 0x2d,
    'image/jpeg' =>
      bytes.length >= 3 &&
          bytes[0] == 0xff &&
          bytes[1] == 0xd8 &&
          bytes[2] == 0xff,
    'image/png' =>
      bytes.length >= 8 &&
          bytes[0] == 0x89 &&
          bytes[1] == 0x50 &&
          bytes[2] == 0x4e &&
          bytes[3] == 0x47 &&
          bytes[4] == 0x0d &&
          bytes[5] == 0x0a &&
          bytes[6] == 0x1a &&
          bytes[7] == 0x0a,
    _ => false,
  };
}
