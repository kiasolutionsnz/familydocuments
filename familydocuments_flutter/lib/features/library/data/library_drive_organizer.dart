import '../../settings/drive/drive_service.dart';
import '../models/library_models.dart';

/// Materialises only confirmed Library destinations under the Family's selected
/// Drive root. It never moves, renames, shares, or deletes an original file.
/// A later explicit move flow can use these registered folder IDs.
class LibraryDriveOrganizer {
  LibraryDriveOrganizer(this.drive);

  final DriveService drive;

  Future<DriveFolder> organiseRentalBill({
    required LibraryRental property,
    required String category,
    DateTime? transactionDate,
  }) async {
    final root = await _libraryRoot();
    final rentals = await _folder(
      key: 'collection:rentals',
      kind: 'collection',
      parent: root.id,
      name: 'Rentals',
    );
    final propertyFolder = await _folder(
      key: 'rental:${property.id}',
      kind: 'rental',
      parent: rentals.id,
      name: property.address.isEmpty ? property.name : property.address,
    );
    final financialYear = _financialYear(transactionDate ?? DateTime.now());
    final year = await _folder(
      key: 'rental:${property.id}:fy:$financialYear',
      kind: 'bucket',
      parent: propertyFolder.id,
      name: 'FY $financialYear',
    );
    return _folder(
      key: 'rental:${property.id}:fy:$financialYear:expense:$category',
      kind: 'bucket',
      parent: year.id,
      name: 'Expenses — ${_label(category)}',
    );
  }

  Future<DriveFolder> organiseTravelRecord({
    required LibraryTrip trip,
    required String kind,
  }) async {
    final root = await _libraryRoot();
    final travel = await _folder(
      key: 'collection:travel',
      kind: 'collection',
      parent: root.id,
      name: 'Travel',
    );
    final year =
        DateTime.tryParse(trip.startDate ?? '')?.year ?? DateTime.now().year;
    final tripFolder = await _folder(
      key: 'trip:${trip.id}',
      kind: 'trip',
      parent: travel.id,
      name: '$year — ${trip.name}',
    );
    return _folder(
      key: 'trip:${trip.id}:$kind',
      kind: 'bucket',
      parent: tripFolder.id,
      name: _travelFolder(kind),
    );
  }

  Future<DriveFolder> _libraryRoot() async {
    final connection = await drive.status();
    final rootId = connection.folderId;
    if (!connection.canSave || rootId == null || rootId.isEmpty) {
      throw const DriveException(
        'Connect the shared Family Drive before organising this record.',
      );
    }
    return _folder(
      key: 'library:root',
      kind: 'library',
      parent: rootId,
      name: 'Library',
    );
  }

  Future<DriveFolder> _folder({
    required String key,
    required String kind,
    required String parent,
    required String name,
  }) => drive.createLibraryFolder(
    nodeKey: key,
    nodeKind: kind,
    parentFolderId: parent,
    name: name,
  );
}

String _financialYear(DateTime date) {
  final start = date.month >= 4 ? date.year : date.year - 1;
  return '$start–${(start + 1).toString().substring(2)}';
}

String _label(String value) => value
    .replaceAll('_', ' ')
    .split(' ')
    .where((word) => word.isNotEmpty)
    .map((word) => '${word[0].toUpperCase()}${word.substring(1)}')
    .join(' ');

String _travelFolder(String kind) => switch (kind) {
  'flight' => 'Flights',
  'accommodation' => 'Accommodation',
  'insurance' => 'Insurance',
  'visa' => 'Passports & visas',
  'activity' => 'Activities',
  _ => 'Other documents',
};
