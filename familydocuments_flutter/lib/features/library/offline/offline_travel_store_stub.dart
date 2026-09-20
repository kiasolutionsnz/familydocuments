import 'dart:typed_data';

import 'offline_travel_models.dart';

OfflineTravelStore createOfflineTravelStore({required String accountId}) =>
    _UnsupportedOfflineStore();

Future<OfflineTravelStore?> openLastOfflineTravelStore() async => null;

class _UnsupportedOfflineStore implements OfflineTravelStore {
  @override
  bool get supported => false;
  @override
  Future<List<OfflineTravelDocument>> list(String tripId) async => const [];
  @override
  Future<List<OfflineTravelDocument>> listAll() async => const [];
  @override
  Future<int> purgeExpired() async => 0;
  @override
  Future<OfflineTravelFile?> read(String documentId) async => null;
  @override
  Future<void> remove(String documentId) async {}
  @override
  Future<void> save({
    required String tripId,
    required String tripTitle,
    required String documentId,
    required String title,
    required String fileName,
    required String mimeType,
    required Uint8List bytes,
    required DateTime expiresAt,
  }) => throw UnsupportedError(
    'Secure offline travel packs are available in the mobile app.',
  );
}
