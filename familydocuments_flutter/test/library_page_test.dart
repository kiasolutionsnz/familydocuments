import 'dart:async';
import 'dart:typed_data';

import 'package:familydocuments_flutter/core/auth/auth_service.dart';
import 'package:familydocuments_flutter/core/home/home_service.dart';
import 'package:familydocuments_flutter/features/library/data/library_service.dart';
import 'package:familydocuments_flutter/features/library/library_navigation.dart';
import 'package:familydocuments_flutter/features/library/library_page.dart';
import 'package:familydocuments_flutter/features/library/models/library_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Auth extends AuthService {
  @override
  Session? get session => Session(
    accessToken: 'fake-access',
    refreshToken: 'fake-refresh',
    email: 'library@example.test',
    userId: 'library-user',
  );
}

class _Navigation implements LibraryNavigation {
  _Navigation([this.value = const LibraryLocation.top()]);
  LibraryLocation value;
  final controller = StreamController<LibraryLocation>.broadcast();

  @override
  LibraryLocation get current => value;
  @override
  Stream<LibraryLocation> get changes => controller.stream;
  @override
  void open(LibraryLocation location) {
    value = location;
    controller.add(location);
  }

  void simulateBack(LibraryLocation location) {
    value = location;
    controller.add(location);
  }

  @override
  void replace(LibraryLocation location) => open(location);
  @override
  void dispose() => controller.close();
}

final _now = DateTime(2027, 1, 20, 12);

LibraryDocument _document(
  String id,
  String title,
  String categoryId,
  String category,
  List<String> tags, {
  bool canEdit = true,
  String? status,
}) => LibraryDocument(
  id: id,
  title: title,
  fileName: '$id.pdf',
  categoryId: categoryId,
  category: category,
  tags: tags,
  savedAt: _now.subtract(Duration(days: int.parse(id.substring(1)))),
  updatedAt: _now,
  fileType: 'application/pdf',
  importantDate: '2028-03-14',
  processingStatus: status,
  sourceAvailable: true,
  canEdit: canEdit,
);

LibraryData _fixture({bool canEdit = true}) => LibraryData(
  categories: const [
    LibraryCategory(id: 'documents', name: 'Documents', count: 1, system: true),
    LibraryCategory(id: 'travel', name: 'Travel', count: 2, system: true),
    LibraryCategory(id: 'rentals', name: 'Rentals', count: 2, system: true),
    LibraryCategory(id: 'finance', name: 'Finance', count: 1, system: true),
    LibraryCategory(id: 'medical', name: 'Medical', count: 1, system: false),
  ],
  documents: [
    _document('d1', 'Family passport', 'documents', 'Documents', [
      'identity',
    ], canEdit: canEdit),
    _document('d2', 'Electricity invoice', 'finance', 'Finance', [
      'invoice',
      'home',
    ], canEdit: canEdit),
    _document('d3', 'Fiji flight', 'travel', 'Travel', [
      'flight',
    ], canEdit: canEdit),
    _document('d4', 'Travel notes', 'travel', 'Travel', [], canEdit: canEdit),
    _document('d5', 'Rental insurance', 'rentals', 'Rentals', [
      'insurance',
    ], canEdit: canEdit),
    _document(
      'd6',
      'Tenancy notes',
      'rentals',
      'Rentals',
      [],
      canEdit: canEdit,
    ),
  ],
  documentTotal: 6,
  documentCount: 6,
  travelCount: 2,
  rentalCount: 2,
  linkCount: 2,
  tags: const ['flight', 'home', 'identity', 'insurance', 'invoice'],
  trips: const [
    LibraryTrip(
      id: 'trip-fiji',
      name: 'Fiji — January 2027',
      destination: 'Fiji',
      startDate: '2027-01-10',
      documentCount: 1,
    ),
    LibraryTrip(
      id: 'trip-sydney',
      name: 'Sydney — April 2027',
      destination: 'Sydney',
      startDate: '2027-04-02',
      documentCount: 0,
    ),
  ],
  travelRecords: const [
    LibraryRelatedDocument(
      id: 'tr1',
      documentId: 'd3',
      title: 'Fiji flight',
      kind: 'flight',
      parentId: 'trip-fiji',
    ),
  ],
  unassignedTravel: const [
    LibraryRelatedDocument(
      id: 'd4',
      documentId: 'd4',
      title: 'Travel notes',
      kind: 'other',
    ),
  ],
  rentals: const [
    LibraryRental(
      id: 'r1',
      name: '12 Example Street',
      address: 'Wellington',
      documentCount: 1,
    ),
    LibraryRental(
      id: 'r2',
      name: '8 Test Road',
      address: 'Auckland',
      documentCount: 0,
    ),
  ],
  rentalRecords: const [
    LibraryRelatedDocument(
      id: 'rr1',
      documentId: 'd5',
      title: 'Rental insurance',
      kind: 'insurance',
      parentId: 'r1',
    ),
  ],
  unassignedRentals: const [
    LibraryRelatedDocument(
      id: 'd6',
      documentId: 'd6',
      title: 'Tenancy notes',
      kind: 'other',
    ),
  ],
  links: [
    LibraryLink(
      id: 'l1',
      title: 'Family travel guide',
      url: 'https://example.test/travel?utm_source=test',
      domain: 'example.test',
      category: 'Travel',
      categoryId: 'lc1',
      savedAt: _now,
    ),
    LibraryLink(
      id: 'l2',
      title: 'Recipe notes',
      url: 'https://recipes.example.test/soup',
      domain: 'recipes.example.test',
      category: 'Recipes',
      categoryId: 'lc2',
      savedAt: _now.subtract(const Duration(days: 1)),
    ),
  ],
  linkCategories: const [
    LibraryCategory(id: 'lc1', name: 'Travel', count: 1, system: false),
    LibraryCategory(id: 'lc2', name: 'Recipes', count: 1, system: false),
  ],
);

class _Service extends LibraryService {
  _Service({LibraryData? data}) : current = data ?? _fixture(), super(_Auth());
  LibraryData current;
  bool failLoad = false, failUpdate = false;
  int loadCalls = 0, updateCalls = 0;

  @override
  Future<LibraryData> load({
    String query = '',
    String? categoryId,
    String? tag,
    LibrarySort sort = LibrarySort.newest,
    int limit = 40,
    int offset = 0,
  }) async {
    loadCalls++;
    if (failLoad) {
      throw const LibraryServiceException(
        'Library could not be loaded. Try again.',
      );
    }
    final q = query.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
    bool matchesDocument(LibraryDocument item) =>
        q.isEmpty ||
        '${item.title} ${item.fileName} ${item.category} ${item.tags.join(' ')}'
            .toLowerCase()
            .contains(q);
    var documents = current.documents
        .where(
          (item) =>
              matchesDocument(item) &&
              (categoryId == null || item.categoryId == categoryId) &&
              (tag == null ||
                  item.tags
                      .map((x) => x.toLowerCase())
                      .contains(tag.toLowerCase())),
        )
        .toList();
    documents.sort(
      (a, b) => switch (sort) {
        LibrarySort.newest => b.savedAt.compareTo(a.savedAt),
        LibrarySort.oldest => a.savedAt.compareTo(b.savedAt),
        LibrarySort.name => a.title.toLowerCase().compareTo(
          b.title.toLowerCase(),
        ),
      },
    );
    final page = documents.skip(offset).take(limit).toList();
    bool match(String value) => q.isEmpty || value.toLowerCase().contains(q);
    return LibraryData(
      categories: current.categories,
      documents: page,
      documentTotal: documents.length,
      documentCount: current.documentCount,
      travelCount: current.travelCount,
      rentalCount: current.rentalCount,
      linkCount: current.linkCount,
      tags: current.tags,
      trips: current.trips
          .where((x) => match('${x.name} ${x.destination ?? ''}'))
          .toList(),
      travelRecords: current.travelRecords,
      unassignedTravel: current.unassignedTravel,
      rentals: current.rentals
          .where((x) => match('${x.name} ${x.address}'))
          .toList(),
      rentalRecords: current.rentalRecords,
      unassignedRentals: current.unassignedRentals,
      links: current.links
          .where((x) => match('${x.title} ${x.domain} ${x.category}'))
          .toList(),
      linkCategories: current.linkCategories,
    );
  }

  @override
  Future<void> updateDocument({
    required LibraryDocument document,
    required String categoryId,
    required List<String> tags,
  }) async {
    updateCalls++;
    if (failUpdate) {
      throw const LibraryServiceException(
        'Changes could not be saved. Try again.',
      );
    }
    final category = current.categories.firstWhere((x) => x.id == categoryId);
    final normalised =
        tags
            .map((x) => x.trim().toLowerCase())
            .where((x) => x.isNotEmpty)
            .toSet()
            .toList()
          ..sort();
    final changed = document.copyWith(
      categoryId: category.id,
      category: category.name,
      tags: normalised,
      updatedAt: _now.add(const Duration(minutes: 1)),
    );
    current = _copy(
      current,
      documents: current.documents
          .map((x) => x.id == document.id ? changed : x)
          .toList(),
    );
  }

  @override
  Future<LibraryCategory> createCategory(String name) async => LibraryCategory(
    id: 'created',
    name: name.trim(),
    count: 0,
    system: false,
  );

  @override
  Future<LibrarySource> source(String documentId) async => LibrarySource(
    fileName: '$documentId.pdf',
    mimeType: 'application/pdf',
    bytes: Uint8List.fromList([1, 2, 3]),
  );
}

LibraryData _copy(
  LibraryData value, {
  required List<LibraryDocument> documents,
}) => LibraryData(
  categories: value.categories,
  documents: documents,
  documentTotal: documents.length,
  documentCount: documents.length,
  travelCount: value.travelCount,
  rentalCount: value.rentalCount,
  linkCount: value.linkCount,
  tags: value.tags,
  trips: value.trips,
  travelRecords: value.travelRecords,
  unassignedTravel: value.unassignedTravel,
  rentals: value.rentals,
  rentalRecords: value.rentalRecords,
  unassignedRentals: value.unassignedRentals,
  links: value.links,
  linkCategories: value.linkCategories,
);

Widget _app(
  _Service service, {
  LibraryNavigation? navigation,
  List<AnalysisJob> jobs = const [],
  LinkOpener? openLink,
  SourceDownloader? download,
}) => MaterialApp(
  home: Scaffold(
    body: LibraryPage(
      service: service,
      processingJobs: jobs,
      onRefreshProcessing: () async {},
      navigation: navigation,
      linkOpener: openLink,
      sourceDownloader: download,
    ),
  ),
);

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pumpAndSettle();
}

void main() {
  test('Library locations restore safely', () {
    expect(LibraryLocation.parse('library/documents/d1').itemId, 'd1');
    expect(LibraryLocation.parse('invalid').section, LibrarySection.top);
  });

  testWidgets('top-level collections use real counts and responsive layouts', (
    tester,
  ) async {
    final service = _Service();
    for (final size in const [Size(390, 844), Size(1200, 900)]) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      await tester.pumpWidget(_app(service));
      await _settle(tester);
      expect(find.text('Everything organised for you.'), findsOneWidget);
      expect(find.text('Documents'), findsOneWidget);
      expect(find.text('Travel'), findsWidgets);
      expect(find.text('Rentals'), findsOneWidget);
      expect(find.text('Saved Links'), findsOneWidget);
      expect(find.text('Finance · 1'), findsOneWidget);
      expect(find.text('Medical · 1'), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
    addTearDown(tester.view.resetPhysicalSize);
  });

  testWidgets(
    'documents search, clear, category/tag filters and sort are predictable',
    (tester) async {
      final service = _Service();
      final navigation = _Navigation(
        const LibraryLocation(LibrarySection.documents),
      );
      await tester.pumpWidget(_app(service, navigation: navigation));
      await _settle(tester);
      expect(find.text('Family passport'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('library-search')),
        '  ELECTRICITY   invoice ',
      );
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(find.text('Electricity invoice'), findsOneWidget);
      expect(find.text('Family passport'), findsNothing);
      await tester.enterText(
        find.byKey(const ValueKey('library-search')),
        'nonexistent',
      );
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(find.text('Nothing matched your search.'), findsOneWidget);
      await tester.tap(find.byTooltip('Clear Library search'));
      await tester.pumpAndSettle();
      expect(find.text('Family passport'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('library-category-filter')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Finance').last);
      await tester.pumpAndSettle();
      expect(find.text('Electricity invoice'), findsOneWidget);
      expect(find.text('Family passport'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('library-category-filter')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('All categories').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('library-tag-filter')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('identity').last);
      await tester.pumpAndSettle();
      expect(find.text('Family passport'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('library-sort')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Name').last);
      await tester.pumpAndSettle();
      expect(service.loadCalls, greaterThan(5));
    },
  );

  testWidgets(
    'global metadata search finds documents and links with an honest empty state',
    (tester) async {
      final service = _Service();
      await tester.pumpWidget(_app(service));
      await _settle(tester);
      await tester.enterText(
        find.byKey(const ValueKey('library-search')),
        'passport',
      );
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(find.text('Family passport'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('library-search')),
        'recipes.example.test',
      );
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(find.text('Recipe notes'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('library-search')),
        'does not exist',
      );
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(find.text('Nothing matched your search.'), findsOneWidget);
    },
  );

  testWidgets(
    'document detail opens source and edits category/tags without duplicates',
    (tester) async {
      final service = _Service();
      final navigation = _Navigation(
        const LibraryLocation(LibrarySection.documents),
      );
      var downloads = 0;
      await tester.pumpWidget(
        _app(
          service,
          navigation: navigation,
          download: (name, mime, bytes) async {
            downloads++;
            return true;
          },
        ),
      );
      await _settle(tester);
      await tester.tap(find.text('Family passport'));
      await tester.pumpAndSettle();
      expect(find.text('Important date'), findsOneWidget);
      await tester.tap(find.text('Open document'));
      await tester.pumpAndSettle();
      expect(downloads, 1);
      await tester.tap(find.byKey(const ValueKey('edit-document')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('edit-category')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Finance').last);
      await tester.enterText(
        find.byKey(const ValueKey('edit-tags')),
        'Identity, identity, Important',
      );
      await tester.tap(find.text('Save changes'));
      await tester.pumpAndSettle();
      expect(service.updateCalls, 1);
      expect(find.text('Finance'), findsWidgets);
      expect(find.text('identity, important'), findsOneWidget);
      expect(find.text('Document details updated.'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('edit-document')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('edit-tags')),
        'Important',
      );
      await tester.tap(find.text('Save changes'));
      await tester.pumpAndSettle();
      expect(service.current.documents.first.tags, ['important']);
    },
  );

  testWidgets(
    'failed metadata edit preserves the original visible state and permits retry',
    (tester) async {
      final service = _Service()..failUpdate = true;
      final navigation = _Navigation(
        const LibraryLocation(LibrarySection.documents, itemId: 'd1'),
      );
      await tester.pumpWidget(_app(service, navigation: navigation));
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('edit-document')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('edit-tags')),
        'changed',
      );
      await tester.tap(find.text('Save changes'));
      await tester.pumpAndSettle();
      expect(
        find.text('Changes could not be saved. Try again.'),
        findsOneWidget,
      );
      expect(service.current.documents.first.tags, ['identity']);
      service.failUpdate = false;
      await tester.tap(find.text('Save changes'));
      await tester.pumpAndSettle();
      expect(service.updateCalls, 2);
    },
  );

  testWidgets('read-only document has no metadata edit action', (tester) async {
    final service = _Service(data: _fixture(canEdit: false));
    final navigation = _Navigation(
      const LibraryLocation(LibrarySection.documents, itemId: 'd1'),
    );
    await tester.pumpWidget(_app(service, navigation: navigation));
    await _settle(tester);
    expect(find.byKey(const ValueKey('edit-document')), findsNothing);
  });

  testWidgets(
    'empty Library, empty collection, and revoked detail use distinct states',
    (tester) async {
      final empty = _fixture();
      final emptyService = _Service(
        data: LibraryData(
          categories: empty.categories,
          documents: const [],
          documentTotal: 0,
          documentCount: 0,
          travelCount: 0,
          rentalCount: 0,
          linkCount: 0,
          tags: const [],
          trips: const [],
          travelRecords: const [],
          unassignedTravel: const [],
          rentals: const [],
          rentalRecords: const [],
          unassignedRentals: const [],
          links: const [],
          linkCategories: const [],
        ),
      );
      await tester.pumpWidget(_app(emptyService));
      await _settle(tester);
      expect(find.text('Nothing has been saved yet.'), findsOneWidget);
      final navigation = _Navigation(
        const LibraryLocation(LibrarySection.documents),
      );
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(_app(emptyService, navigation: navigation));
      await _settle(tester);
      expect(find.text('No documents in this collection.'), findsOneWidget);
      navigation.simulateBack(
        const LibraryLocation(LibrarySection.documents, itemId: 'revoked'),
      );
      await tester.pumpAndSettle();
      expect(
        find.text('You no longer have access to this item.'),
        findsOneWidget,
      );
    },
  );

  testWidgets('Travel and Rentals group assigned and unassigned real records', (
    tester,
  ) async {
    final service = _Service();
    final navigation = _Navigation(
      const LibraryLocation(LibrarySection.travel),
    );
    await tester.pumpWidget(_app(service, navigation: navigation));
    await _settle(tester);
    expect(find.text('Fiji — January 2027'), findsOneWidget);
    expect(find.text('Other travel documents'), findsOneWidget);
    expect(find.text('Travel notes'), findsOneWidget);
    await tester.tap(find.text('Fiji — January 2027'));
    await tester.pumpAndSettle();
    expect(find.text('Flights'), findsOneWidget);
    expect(find.text('Fiji flight'), findsOneWidget);
    navigation.simulateBack(const LibraryLocation(LibrarySection.rentals));
    await tester.pumpAndSettle();
    expect(find.text('12 Example Street'), findsOneWidget);
    expect(find.text('Other rental documents'), findsOneWidget);
    expect(find.text('Tenancy notes'), findsOneWidget);
    await tester.tap(find.text('12 Example Street'));
    await tester.pumpAndSettle();
    expect(find.text('Insurance'), findsOneWidget);
    expect(find.text('Rental insurance'), findsOneWidget);
  });

  testWidgets(
    'Saved Links group by category, filter, and open only through the safe callback',
    (tester) async {
      final service = _Service();
      final navigation = _Navigation(
        const LibraryLocation(LibrarySection.links),
      );
      String? opened;
      await tester.pumpWidget(
        _app(
          service,
          navigation: navigation,
          openLink: (url) async {
            opened = url;
            return true;
          },
        ),
      );
      await _settle(tester);
      expect(find.text('Travel'), findsOneWidget);
      expect(find.text('Recipes'), findsOneWidget);
      expect(find.text('example.test'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('link-category-filter')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Recipes').last);
      await tester.pumpAndSettle();
      expect(find.text('Family travel guide'), findsNothing);
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(opened, 'https://recipes.example.test/soup');
    },
  );

  testWidgets(
    'processing status is shared and completion updates one document without duplication',
    (tester) async {
      final service = _Service();
      final navigation = _Navigation(
        const LibraryLocation(LibrarySection.documents),
      );
      const queued = AnalysisJob(
        id: 'job',
        documentId: 'd1',
        status: 'processing',
      );
      await tester.pumpWidget(
        _app(service, navigation: navigation, jobs: const [queued]),
      );
      await _settle(tester);
      expect(find.text('Reading'), findsOneWidget);
      expect(find.byKey(const ValueKey('library-document-d1')), findsOneWidget);
      const finished = AnalysisJob(
        id: 'job',
        documentId: 'd1',
        status: 'succeeded',
        result: OrganisedDocument(
          title: 'Family passport',
          category: 'Travel',
          tags: ['classified'],
          pageCount: 1,
        ),
      );
      await tester.pumpWidget(
        _app(service, navigation: navigation, jobs: const [finished]),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('library-document-d1')), findsOneWidget);
      expect(find.text('classified'), findsOneWidget);
    },
  );

  testWidgets('restored collection and browser Back state are honoured', (
    tester,
  ) async {
    final service = _Service();
    final navigation = _Navigation(
      const LibraryLocation(LibrarySection.documents, itemId: 'd1'),
    );
    await tester.pumpWidget(_app(service, navigation: navigation));
    await _settle(tester);
    expect(find.text('Important date'), findsOneWidget);
    navigation.simulateBack(const LibraryLocation(LibrarySection.documents));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('library-document-d1')), findsOneWidget);
    navigation.simulateBack(const LibraryLocation.top());
    await tester.pumpAndSettle();
    expect(find.text('Everything organised for you.'), findsOneWidget);
  });

  testWidgets('initial error and Retry recover without hiding existing data', (
    tester,
  ) async {
    final service = _Service()..failLoad = true;
    await tester.pumpWidget(_app(service));
    await _settle(tester);
    expect(
      find.text('Library could not be loaded. Try again.'),
      findsOneWidget,
    );
    service.failLoad = false;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.text('Everything organised for you.'), findsOneWidget);
  });
}
