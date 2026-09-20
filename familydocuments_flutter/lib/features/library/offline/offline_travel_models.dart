import 'dart:typed_data';

class OfflineTravelDocument {
  const OfflineTravelDocument({
    required this.documentId,
    required this.tripId,
    required this.tripTitle,
    required this.title,
    required this.fileName,
    required this.mimeType,
    required this.savedAt,
    required this.expiresAt,
  });

  final String documentId, tripId, tripTitle, title, fileName, mimeType;
  final DateTime savedAt, expiresAt;

  bool get expired => !expiresAt.isAfter(DateTime.now());

  Map<String, dynamic> toJson() => {
    'document_id': documentId,
    'trip_id': tripId,
    'trip_title': tripTitle,
    'title': title,
    'file_name': fileName,
    'mime_type': mimeType,
    'saved_at': savedAt.toUtc().toIso8601String(),
    'expires_at': expiresAt.toUtc().toIso8601String(),
  };

  factory OfflineTravelDocument.fromJson(Map<String, dynamic> value) =>
      OfflineTravelDocument(
        documentId: value['document_id']?.toString() ?? '',
        tripId: value['trip_id']?.toString() ?? '',
        tripTitle: value['trip_title']?.toString() ?? 'Travel',
        title: value['title']?.toString() ?? 'Travel document',
        fileName: value['file_name']?.toString() ?? 'document',
        mimeType: value['mime_type']?.toString() ?? '',
        savedAt: DateTime.parse(value['saved_at'].toString()).toLocal(),
        expiresAt: DateTime.parse(value['expires_at'].toString()).toLocal(),
      );
}

class OfflineTravelFile {
  const OfflineTravelFile({required this.document, required this.bytes});
  final OfflineTravelDocument document;
  final Uint8List bytes;
}

abstract class OfflineTravelStore {
  bool get supported;
  Future<List<OfflineTravelDocument>> list(String tripId);
  Future<List<OfflineTravelDocument>> listAll();
  Future<void> save({
    required String tripId,
    required String tripTitle,
    required String documentId,
    required String title,
    required String fileName,
    required String mimeType,
    required Uint8List bytes,
    required DateTime expiresAt,
  });
  Future<OfflineTravelFile?> read(String documentId);
  Future<void> remove(String documentId);
  Future<int> purgeExpired();
}
