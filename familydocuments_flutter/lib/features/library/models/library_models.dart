enum LibrarySort { newest, oldest, name }

enum LibrarySection { top, documents, travel, rentals, links, category }

class LibraryLocation {
  const LibraryLocation(this.section, {this.itemId});

  const LibraryLocation.top() : this(LibrarySection.top);

  final LibrarySection section;
  final String? itemId;

  String get value => switch (section) {
    LibrarySection.top => 'library',
    _ => 'library/${section.name}${itemId == null ? '' : '/$itemId'}',
  };

  static LibraryLocation parse(String value) {
    final parts = value.split('/');
    if (parts.isEmpty || parts.first != 'library') {
      return const LibraryLocation.top();
    }
    if (parts.length == 1) return const LibraryLocation.top();
    final section = LibrarySection.values
        .where((x) => x.name == parts[1])
        .firstOrNull;
    if (section == null || section == LibrarySection.top) {
      return const LibraryLocation.top();
    }
    return LibraryLocation(section, itemId: parts.length > 2 ? parts[2] : null);
  }
}

class LibraryCategory {
  const LibraryCategory({
    required this.id,
    required this.name,
    required this.count,
    required this.system,
  });
  final String id, name;
  final int count;
  final bool system;

  factory LibraryCategory.fromJson(Map value) => LibraryCategory(
    id: value['id']?.toString() ?? '',
    name: value['name']?.toString() ?? 'Category',
    count: (value['count'] as num?)?.toInt() ?? 0,
    system: value['is_system'] == true,
  );
}

class LibraryDocument {
  const LibraryDocument({
    required this.id,
    required this.title,
    required this.categoryId,
    required this.category,
    required this.tags,
    required this.savedAt,
    required this.updatedAt,
    required this.fileType,
    required this.canEdit,
    this.fileName,
    this.documentDate,
    this.importantDate,
    this.processingStatus,
    this.sourceAvailable = false,
  });

  final String id, title, categoryId, category, fileType;
  final String? fileName, documentDate, importantDate, processingStatus;
  final List<String> tags;
  final DateTime savedAt, updatedAt;
  final bool canEdit, sourceAvailable;

  factory LibraryDocument.fromJson(Map value) => LibraryDocument(
    id: value['id']?.toString() ?? '',
    title:
        value['title']?.toString() ??
        value['file_name']?.toString() ??
        'Document',
    fileName: value['file_name']?.toString(),
    categoryId: value['category_id']?.toString() ?? '',
    category: value['category']?.toString() ?? 'Documents',
    tags:
        (value['tags'] as List?)
            ?.map((x) => x.toString())
            .where((x) => x.isNotEmpty)
            .toList() ??
        const [],
    savedAt:
        DateTime.tryParse(value['saved_at']?.toString() ?? '')?.toLocal() ??
        DateTime.fromMillisecondsSinceEpoch(0),
    updatedAt:
        DateTime.tryParse(value['updated_at']?.toString() ?? '')?.toLocal() ??
        DateTime.fromMillisecondsSinceEpoch(0),
    fileType: value['file_type']?.toString() ?? 'document',
    documentDate: value['document_date']?.toString(),
    importantDate: value['important_date']?.toString(),
    processingStatus: value['processing_status']?.toString(),
    sourceAvailable: value['source_available'] == true,
    canEdit: value['can_edit'] == true,
  );

  LibraryDocument copyWith({
    String? categoryId,
    String? category,
    List<String>? tags,
    DateTime? updatedAt,
    String? processingStatus,
  }) => LibraryDocument(
    id: id,
    title: title,
    fileName: fileName,
    categoryId: categoryId ?? this.categoryId,
    category: category ?? this.category,
    tags: tags ?? this.tags,
    savedAt: savedAt,
    updatedAt: updatedAt ?? this.updatedAt,
    fileType: fileType,
    documentDate: documentDate,
    importantDate: importantDate,
    processingStatus: processingStatus ?? this.processingStatus,
    sourceAvailable: sourceAvailable,
    canEdit: canEdit,
  );
}

class LibraryTrip {
  const LibraryTrip({
    required this.id,
    required this.name,
    required this.documentCount,
    this.destination,
    this.startDate,
    this.endDate,
  });
  final String id, name;
  final String? destination, startDate, endDate;
  final int documentCount;
  factory LibraryTrip.fromJson(Map value) => LibraryTrip(
    id: value['id']?.toString() ?? '',
    name: value['name']?.toString() ?? 'Trip',
    destination: value['destination']?.toString(),
    startDate: value['start_date']?.toString(),
    endDate: value['end_date']?.toString(),
    documentCount: (value['document_count'] as num?)?.toInt() ?? 0,
  );
}

class LibraryRental {
  const LibraryRental({
    required this.id,
    required this.name,
    required this.address,
    required this.documentCount,
  });
  final String id, name, address;
  final int documentCount;
  factory LibraryRental.fromJson(Map value) => LibraryRental(
    id: value['id']?.toString() ?? '',
    name: value['name']?.toString() ?? 'Rental',
    address: value['address']?.toString() ?? '',
    documentCount: (value['document_count'] as num?)?.toInt() ?? 0,
  );
}

class LibraryRelatedDocument {
  const LibraryRelatedDocument({
    required this.id,
    required this.documentId,
    required this.title,
    required this.kind,
    this.parentId,
  });
  final String id, documentId, title, kind;
  final String? parentId;
  factory LibraryRelatedDocument.fromJson(Map value, String parentKey) =>
      LibraryRelatedDocument(
        id: value['id']?.toString() ?? '',
        documentId:
            value['document_id']?.toString() ?? value['id']?.toString() ?? '',
        title: value['title']?.toString() ?? 'Document',
        kind: value['kind']?.toString() ?? 'other',
        parentId: value[parentKey]?.toString(),
      );
}

class LibraryLink {
  const LibraryLink({
    required this.id,
    required this.title,
    required this.url,
    required this.domain,
    required this.category,
    required this.savedAt,
    this.categoryId,
    this.tags = const [],
  });
  final String id, title, url, domain, category;
  final String? categoryId;
  final DateTime savedAt;
  final List<String> tags;
  factory LibraryLink.fromJson(Map value) => LibraryLink(
    id: value['id']?.toString() ?? '',
    title: value['title']?.toString() ?? 'Saved link',
    url: value['url']?.toString() ?? '',
    domain: value['domain']?.toString() ?? '',
    category: value['category']?.toString() ?? 'Saved Links',
    categoryId: value['category_id']?.toString(),
    savedAt:
        DateTime.tryParse(value['saved_at']?.toString() ?? '')?.toLocal() ??
        DateTime.fromMillisecondsSinceEpoch(0),
    tags:
        (value['tags'] as List?)?.map((x) => x.toString()).toList() ?? const [],
  );
}

class LibraryData {
  const LibraryData({
    required this.categories,
    required this.documents,
    required this.documentTotal,
    required this.documentCount,
    required this.travelCount,
    required this.rentalCount,
    required this.linkCount,
    required this.tags,
    required this.trips,
    required this.travelRecords,
    required this.unassignedTravel,
    required this.rentals,
    required this.rentalRecords,
    required this.unassignedRentals,
    required this.links,
    required this.linkCategories,
  });
  final List<LibraryCategory> categories;
  final List<LibraryDocument> documents;
  final int documentTotal, documentCount, travelCount, rentalCount, linkCount;
  final List<String> tags;
  final List<LibraryTrip> trips;
  final List<LibraryRelatedDocument> travelRecords, unassignedTravel;
  final List<LibraryRental> rentals;
  final List<LibraryRelatedDocument> rentalRecords, unassignedRentals;
  final List<LibraryLink> links;
  final List<LibraryCategory> linkCategories;

  factory LibraryData.fromJson(Map<String, dynamic> value) => LibraryData(
    categories: _maps(value['categories'])
        .map(LibraryCategory.fromJson)
        .toList(),
    documents: _maps(value['documents']).map(LibraryDocument.fromJson).toList(),
    documentTotal: (value['document_total'] as num?)?.toInt() ?? 0,
    documentCount: (value['document_count'] as num?)?.toInt() ?? 0,
    travelCount: (value['travel_count'] as num?)?.toInt() ?? 0,
    rentalCount: (value['rental_count'] as num?)?.toInt() ?? 0,
    linkCount: (value['link_count'] as num?)?.toInt() ?? 0,
    tags:
        (value['tags'] as List?)?.map((x) => x.toString()).toList() ?? const [],
    trips: _maps(value['trips']).map(LibraryTrip.fromJson).toList(),
    travelRecords: _maps(value['travel_records'])
        .map((x) => LibraryRelatedDocument.fromJson(x, 'trip_id'))
        .toList(),
    unassignedTravel: _maps(value['unassigned_travel'])
        .map((x) => LibraryRelatedDocument.fromJson(x, 'trip_id'))
        .toList(),
    rentals: _maps(value['rentals']).map(LibraryRental.fromJson).toList(),
    rentalRecords: _maps(value['rental_records'])
        .map((x) => LibraryRelatedDocument.fromJson(x, 'property_id'))
        .toList(),
    unassignedRentals: _maps(value['unassigned_rentals'])
        .map((x) => LibraryRelatedDocument.fromJson(x, 'property_id'))
        .toList(),
    links: _maps(value['links']).map(LibraryLink.fromJson).toList(),
    linkCategories: _maps(value['link_categories'])
        .map(
          (value) => LibraryCategory(
            id: value['id']?.toString() ?? '',
            name: value['name']?.toString() ?? 'Links',
            count: 0,
            system: false,
          ),
        )
        .toList(),
  );
}

List<Map> _maps(dynamic value) =>
    (value as List?)?.whereType<Map>().toList() ?? const [];

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
