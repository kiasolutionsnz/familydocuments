import 'dart:typed_data';

const int maxSelectedUploadBytes = 5 * 1024 * 1024;

class SelectedUploadException implements Exception {
  const SelectedUploadException(this.message);

  final String message;
}

class SelectedUpload {
  const SelectedUpload({
    required this.name,
    required this.bytes,
    required this.mimeType,
  });

  final String name;
  final Uint8List bytes;
  final String mimeType;
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
