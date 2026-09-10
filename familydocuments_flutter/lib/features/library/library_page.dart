import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../core/home/home_service.dart';
import '../../core/security/public_https_url.dart';
import 'data/library_service.dart';
import 'library_navigation.dart';
import 'models/library_models.dart';
import 'safe_open.dart';

typedef LinkOpener = Future<bool> Function(String url);
typedef SourceDownloader = Future<bool> Function(
  String name,
  String mimeType,
  List<int> bytes,
);

class LibraryPage extends StatefulWidget {
  const LibraryPage({
    super.key,
    required this.service,
    required this.processingJobs,
    required this.onRefreshProcessing,
    this.navigation,
    this.linkOpener,
    this.sourceDownloader,
    this.onMetadataChanged,
  });

  final LibraryService service;
  final List<AnalysisJob> processingJobs;
  final Future<void> Function() onRefreshProcessing;
  final LibraryNavigation? navigation;
  final LinkOpener? linkOpener;
  final SourceDownloader? sourceDownloader;
  final VoidCallback? onMetadataChanged;

  @override
  State<LibraryPage> createState() => LibraryPageState();
}

class LibraryPageState extends State<LibraryPage> {
  final search = TextEditingController();
  Timer? debounce;
  late final LibraryNavigation navigation;
  late final bool ownsNavigation;
  StreamSubscription<LibraryLocation>? navigationSubscription;
  LibraryLocation location = const LibraryLocation.top();
  LibraryData? data;
  bool loading = false, loadingMore = false;
  String? error, categoryFilter, tagFilter, linkCategoryFilter;
  LibrarySort sort = LibrarySort.newest;

  @override
  void initState() {
    super.initState();
    ownsNavigation = widget.navigation == null;
    navigation = widget.navigation ?? createLibraryNavigation();
    location = navigation.current;
    navigationSubscription = navigation.changes.listen((value) {
      if (mounted) setState(() => location = value);
    });
    _load();
  }

  @override
  void didUpdateWidget(covariant LibraryPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldStatuses = {
      for (final job in oldWidget.processingJobs) job.id: job.status,
    };
    if (widget.processingJobs.any(
      (job) => oldStatuses[job.id] != job.status && job.terminal,
    )) {
      unawaited(_load());
    }
  }

  @override
  void dispose() {
    debounce?.cancel();
    search.dispose();
    navigationSubscription?.cancel();
    if (ownsNavigation) navigation.dispose();
    super.dispose();
  }

  Future<void> refresh() async {
    await widget.onRefreshProcessing();
    await _load();
  }

  Future<void> _load({bool more = false}) async {
    if (more ? loadingMore : loading) {
      if (!more && data == null) return;
    }
    setState(() {
      if (more) {
        loadingMore = true;
      } else {
        loading = true;
        error = null;
      }
    });
    try {
      final next = await widget.service.load(
        query: search.text,
        categoryId: categoryFilter,
        tag: tagFilter,
        sort: sort,
        offset: more ? (data?.documents.length ?? 0) : 0,
      );
      if (!mounted) return;
      if (more && data != null) {
        final existing = {
          for (final document in data!.documents) document.id: document,
        };
        for (final document in next.documents) {
          existing[document.id] = document;
        }
        data = LibraryData(
          categories: next.categories,
          documents: existing.values.toList(),
          documentTotal: next.documentTotal,
          documentCount: next.documentCount,
          travelCount: next.travelCount,
          rentalCount: next.rentalCount,
          linkCount: next.linkCount,
          trips: next.trips,
          travelRecords: next.travelRecords,
          unassignedTravel: next.unassignedTravel,
          rentals: next.rentals,
          rentalRecords: next.rentalRecords,
          unassignedRentals: next.unassignedRentals,
          links: next.links,
          linkCategories: next.linkCategories,
          tags: next.tags,
        );
      } else {
        data = next;
      }
      error = null;
    } on LibraryServiceException catch (failure) {
      if (mounted) error = failure.message;
    } catch (_) {
      if (mounted) error = 'Library could not be loaded. Try again.';
    } finally {
      if (mounted) {
        setState(() {
          loading = false;
          loadingMore = false;
        });
      }
    }
  }

  void _searchChanged(String _) {
    debounce?.cancel();
    debounce = Timer(const Duration(milliseconds: 350), _load);
  }

  void _open(LibraryLocation next) {
    navigation.open(next);
    setState(() => location = next);
  }

  void _backTo(LibraryLocation next) => _open(next);

  List<LibraryDocument> get documents {
    final byId = {
      for (final item in data?.documents ?? const <LibraryDocument>[])
        item.id: item,
    };
    for (final job in widget.processingJobs) {
      final current = byId[job.documentId];
      if (current == null) continue;
      byId[job.documentId] = current.copyWith(
        category: job.result?.category ?? job.category,
        tags: job.result?.tags ?? (job.tags.isEmpty ? null : job.tags),
        processingStatus: job.status,
        updatedAt: job.updatedAt,
      );
    }
    return byId.values.toList();
  }

  @override
  Widget build(BuildContext context) {
    if (loading && data == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (error != null && data == null) {
      return _StateView(
        message: error!,
        action: TextButton(onPressed: _load, child: const Text('Retry')),
      );
    }
    final content = switch (location.section) {
      LibrarySection.top => _top(),
      LibrarySection.documents =>
        location.itemId == null
            ? _documents()
            : _documentDetail(location.itemId!),
      LibrarySection.category => _documents(categoryId: location.itemId),
      LibrarySection.travel =>
        location.itemId == null ? _travel() : _trip(location.itemId!),
      LibrarySection.rentals =>
        location.itemId == null ? _rentals() : _rental(location.itemId!),
      LibrarySection.links => _links(),
    };
    return RefreshIndicator(
      onRefresh: refresh,
      child: ListView(
        key: ValueKey('library-${location.value}'),
        padding: const EdgeInsets.fromLTRB(20, 24, 20, 96),
        children: [
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 980),
              child: content,
            ),
          ),
        ],
      ),
    );
  }

  Widget _heading(String title, {String? subtitle, LibraryLocation? back}) =>
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (back != null)
            TextButton.icon(
              onPressed: () => _backTo(back),
              icon: const Icon(Icons.arrow_back),
              label: const Text('Back'),
            ),
          Text(
            title,
            style: const TextStyle(
              fontSize: 30,
              fontWeight: FontWeight.w700,
              color: Color(0xff17233a),
            ),
          ),
          if (subtitle != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                subtitle,
                style: const TextStyle(color: Color(0xff657083)),
              ),
            ),
        ],
      );

  Widget _search() => Padding(
    padding: const EdgeInsets.symmetric(vertical: 20),
    child: TextField(
      key: const ValueKey('library-search'),
      controller: search,
      onChanged: _searchChanged,
      decoration: InputDecoration(
        prefixIcon: const Icon(Icons.search),
        hintText: 'Search your Library',
        suffixIcon: search.text.isEmpty
            ? null
            : IconButton(
                tooltip: 'Clear Library search',
                onPressed: () {
                  search.clear();
                  _load();
                },
                icon: const Icon(Icons.close),
              ),
        border: const OutlineInputBorder(),
      ),
    ),
  );

  Widget _top() {
    final value = data!;
    final collections = [
      (
        'Documents',
        Icons.description_outlined,
        value.documentCount,
        const LibraryLocation(LibrarySection.documents),
      ),
      (
        'Travel',
        Icons.flight_outlined,
        value.travelCount,
        const LibraryLocation(LibrarySection.travel),
      ),
      (
        'Rentals',
        Icons.home_work_outlined,
        value.rentalCount,
        const LibraryLocation(LibrarySection.rentals),
      ),
      (
        'Saved Links',
        Icons.link,
        value.linkCount,
        const LibraryLocation(LibrarySection.links),
      ),
    ];
    final categories = value.categories
        .where(
          (c) =>
              c.count > 0 &&
              !{
                'documents',
                'travel',
                'rentals',
                'rental records',
              }.contains(c.name.toLowerCase()),
        )
        .toList();
    final noContent = value.documentCount == 0 && value.linkCount == 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _heading('Library', subtitle: 'Everything organised for you.'),
        _search(),
        if (error != null) _InlineError(error!, _load),
        if (search.text.trim().isNotEmpty)
          _topSearchResults(value)
        else if (noContent)
          const _StateView(message: 'Nothing has been saved yet.')
        else
          LayoutBuilder(
            builder: (context, constraints) {
              final columns = constraints.maxWidth >= 720 ? 2 : 1;
              return GridView.count(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                crossAxisCount: columns,
                childAspectRatio: columns == 2 ? 3.3 : 3.6,
                crossAxisSpacing: 12,
                mainAxisSpacing: 12,
                children: collections
                    .map(
                      (item) => _CollectionCard(
                        title: item.$1,
                        icon: item.$2,
                        count: item.$3,
                        onTap: () => _open(item.$4),
                      ),
                    )
                    .toList(),
              );
            },
          ),
        if (categories.isNotEmpty) ...[
          const Padding(
            padding: EdgeInsets.only(top: 28, bottom: 10),
            child: Text(
              'Family categories',
              style: TextStyle(fontSize: 19, fontWeight: FontWeight.w700),
            ),
          ),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: categories
                .map(
                  (category) => ActionChip(
                    avatar: const Icon(Icons.folder_outlined, size: 18),
                    label: Text('${category.name} · ${category.count}'),
                    onPressed: () => _open(
                      LibraryLocation(
                        LibrarySection.category,
                        itemId: category.id,
                      ),
                    ),
                  ),
                )
                .toList(),
          ),
        ],
      ],
    );
  }

  Widget _topSearchResults(LibraryData value) {
    final hasMatches =
        value.documents.isNotEmpty ||
        value.trips.isNotEmpty ||
        value.rentals.isNotEmpty ||
        value.links.isNotEmpty;
    if (!hasMatches) {
      return const _StateView(message: 'Nothing matched your search.');
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ...value.documents.map(
          (document) => _DocumentRow(
            document: document,
            onTap: () => _open(
              LibraryLocation(LibrarySection.documents, itemId: document.id),
            ),
          ),
        ),
        ...value.trips.map(
          (trip) => _CollectionCard(
            title: trip.name,
            subtitle: trip.destination,
            icon: Icons.flight_outlined,
            count: trip.documentCount,
            onTap: () =>
                _open(LibraryLocation(LibrarySection.travel, itemId: trip.id)),
          ),
        ),
        ...value.rentals.map(
          (rental) => _CollectionCard(
            title: rental.name,
            subtitle: rental.address,
            icon: Icons.home_work_outlined,
            count: rental.documentCount,
            onTap: () => _open(
              LibraryLocation(LibrarySection.rentals, itemId: rental.id),
            ),
          ),
        ),
        ...value.links.map(
          (link) => ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.link),
            title: Text(link.title),
            subtitle: Text(link.domain),
            trailing: TextButton(
              onPressed: () => _safeOpen(link.url),
              child: const Text('Open'),
            ),
          ),
        ),
      ],
    );
  }

  Widget _documents({String? categoryId}) {
    final category = data!.categories
        .where((x) => x.id == categoryId)
        .firstOrNull;
    final shown = documents
        .where(
          (document) => categoryId == null || document.categoryId == categoryId,
        )
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _heading(
          category?.name ?? 'Documents',
          subtitle: category == null
              ? 'Saved documents and their organisation.'
              : null,
          back: const LibraryLocation.top(),
        ),
        _search(),
        _documentControls(categoryId),
        if (error != null) _InlineError(error!, _load),
        if (shown.isEmpty)
          _StateView(
            message: search.text.isNotEmpty
                ? 'Nothing matched your search.'
                : (categoryFilter != null || tagFilter != null
                      ? 'No documents match these filters.'
                      : 'No documents in this collection.'),
          )
        else
          ...shown.map(
            (document) => _DocumentRow(
              document: document,
              onTap: () => _open(
                LibraryLocation(LibrarySection.documents, itemId: document.id),
              ),
            ),
          ),
        if (shown.length < data!.documentTotal)
          Center(
            child: TextButton(
              onPressed: loadingMore ? null : () => _load(more: true),
              child: Text(loadingMore ? 'Loading…' : 'Load more'),
            ),
          ),
      ],
    );
  }

  Widget _documentControls(String? fixedCategory) => Wrap(
    spacing: 10,
    runSpacing: 8,
    crossAxisAlignment: WrapCrossAlignment.center,
    children: [
      DropdownButton<String?>(
        key: const ValueKey('library-category-filter'),
        value: fixedCategory ?? categoryFilter,
        hint: const Text('All categories'),
        items: [
          const DropdownMenuItem(value: null, child: Text('All categories')),
          ...data!.categories.map(
            (c) => DropdownMenuItem(value: c.id, child: Text(c.name)),
          ),
        ],
        onChanged: fixedCategory != null
            ? null
            : (value) {
                setState(() => categoryFilter = value);
                _load();
              },
      ),
      DropdownButton<String?>(
        key: const ValueKey('library-tag-filter'),
        value: tagFilter,
        hint: const Text('All tags'),
        items: [
          const DropdownMenuItem(value: null, child: Text('All tags')),
          ...data!.tags.map(
            (tag) => DropdownMenuItem(value: tag, child: Text(tag)),
          ),
        ],
        onChanged: (value) {
          setState(() => tagFilter = value);
          _load();
        },
      ),
      DropdownButton<LibrarySort>(
        key: const ValueKey('library-sort'),
        value: sort,
        items: const [
          DropdownMenuItem(value: LibrarySort.newest, child: Text('Newest')),
          DropdownMenuItem(value: LibrarySort.oldest, child: Text('Oldest')),
          DropdownMenuItem(value: LibrarySort.name, child: Text('Name')),
        ],
        onChanged: (value) {
          if (value == null) return;
          setState(() => sort = value);
          _load();
        },
      ),
    ],
  );

  Widget _documentDetail(String id) {
    final document = documents.where((x) => x.id == id).firstOrNull;
    if (document == null) {
      return _StateView(
        message: 'You no longer have access to this item.',
        action: TextButton(
          onPressed: () =>
              _backTo(const LibraryLocation(LibrarySection.documents)),
          child: const Text('Back to Documents'),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _heading(
          document.title,
          back: const LibraryLocation(LibrarySection.documents),
        ),
        const SizedBox(height: 18),
        _DetailLine('Category', document.category),
        _DetailLine(
          'Tags',
          document.tags.isEmpty ? 'No tags' : document.tags.join(', '),
        ),
        _DetailLine('Saved', _date(document.savedAt)),
        _DetailLine('File type', _fileType(document.fileType)),
        if (document.importantDate != null)
          _DetailLine('Important date', document.importantDate!),
        if (document.processingStatus case final status?
            when {
              'queued',
              'retry_wait',
              'processing',
              'failed',
              'permanent_failed',
            }.contains(status))
          _DetailLine('Status', _status(status)),
        const SizedBox(height: 16),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            if (document.sourceAvailable)
              FilledButton.icon(
                onPressed: () => _openSource(document),
                icon: const Icon(Icons.open_in_new),
                label: const Text('Open document'),
              ),
            if (document.canEdit)
              OutlinedButton.icon(
                key: const ValueKey('edit-document'),
                onPressed: () => _editDocument(document),
                icon: const Icon(Icons.edit_outlined),
                label: const Text('Edit details'),
              ),
          ],
        ),
      ],
    );
  }

  Future<void> _openSource(LibraryDocument document) async {
    try {
      final source = await widget.service.source(document.id);
      final downloader =
          widget.sourceDownloader ??
          (name, mime, bytes) =>
              downloadDocument(name, mime, Uint8List.fromList(bytes));
      final opened = await downloader(
        source.fileName,
        source.mimeType,
        source.bytes,
      );
      if (!opened && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Opening files is not available on this device yet.'),
          ),
        );
      }
    } on LibraryServiceException catch (failure) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(failure.message)));
      }
    }
  }

  Future<void> _editDocument(LibraryDocument document) async {
    var selectedCategory = document.categoryId;
    var tagsText = document.tags.join(', ');
    String? dialogError;
    final availableCategories = [...data!.categories];
    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Edit document details'),
          content: SizedBox(
            width: 460,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<String>(
                  key: const ValueKey('edit-category'),
                  initialValue: selectedCategory,
                  decoration: const InputDecoration(labelText: 'Category'),
                  items: [
                    ...availableCategories.map(
                      (c) => DropdownMenuItem(value: c.id, child: Text(c.name)),
                    ),
                    const DropdownMenuItem(
                      value: '__create__',
                      child: Text('Create a new category…'),
                    ),
                  ],
                  onChanged: (value) async {
                    if (value == '__create__') {
                      final created = await _createCategory(dialogContext);
                      if (created != null) {
                        setDialogState(() {
                          availableCategories.add(created);
                          selectedCategory = created.id;
                        });
                      }
                    } else if (value != null) {
                      setDialogState(() => selectedCategory = value);
                    }
                  },
                ),
                const SizedBox(height: 14),
                TextFormField(
                  key: const ValueKey('edit-tags'),
                  initialValue: tagsText,
                  onChanged: (value) => tagsText = value,
                  decoration: const InputDecoration(
                    labelText: 'Tags',
                    helperText: 'Separate tags with commas',
                  ),
                ),
                if (dialogError != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(
                      dialogError!,
                      style: const TextStyle(color: Colors.red),
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () async {
                try {
                  await widget.service.updateDocument(
                    document: document,
                    categoryId: selectedCategory,
                    tags: tagsText.split(','),
                  );
                  if (dialogContext.mounted) Navigator.pop(dialogContext, true);
                } on LibraryServiceException catch (failure) {
                  setDialogState(() => dialogError = failure.message);
                }
              },
              child: const Text('Save changes'),
            ),
          ],
        ),
      ),
    );
    if (saved == true && mounted) {
      await _load();
      widget.onMetadataChanged?.call();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Document details updated.')),
        );
      }
    }
  }

  Future<LibraryCategory?> _createCategory(BuildContext parent) async {
    var categoryName = '';
    final confirmed = await showDialog<bool>(
      context: parent,
      builder: (context) => AlertDialog(
        title: const Text('Create category?'),
        content: TextFormField(
          key: const ValueKey('new-category-name'),
          onChanged: (value) => categoryName = value,
          decoration: const InputDecoration(labelText: 'Category name'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Create'),
          ),
        ],
      ),
    );
    if (confirmed != true || categoryName.trim().isEmpty) {
      return null;
    }
    return widget.service.createCategory(categoryName);
  }

  Widget _travel() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      _heading(
        'Travel',
        subtitle: 'Documents organised by trip.',
        back: const LibraryLocation.top(),
      ),
      _search(),
      if (data!.trips.isEmpty && data!.travelRecords.isEmpty)
        const _StateView(message: 'No documents in this collection.'),
      ...data!.trips.map(
        (trip) => _CollectionCard(
          title: trip.name,
          subtitle: [
            trip.destination,
            trip.startDate,
          ].whereType<String>().join(' · '),
          icon: Icons.flight_outlined,
          count: trip.documentCount,
          onTap: () =>
              _open(LibraryLocation(LibrarySection.travel, itemId: trip.id)),
        ),
      ),
      if (data!.unassignedTravel.isNotEmpty) ...[
        _subheading('Other travel documents'),
        ...data!.unassignedTravel.map(_relatedRow),
      ],
    ],
  );

  Widget _trip(String id) {
    final trip = data!.trips.where((x) => x.id == id).firstOrNull;
    if (trip == null) {
      return _StateView(message: 'You no longer have access to this item.');
    }
    final records = data!.travelRecords.where((x) => x.parentId == id).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _heading(
          trip.name,
          subtitle: [
            trip.destination,
            trip.startDate,
          ].whereType<String>().join(' · '),
          back: const LibraryLocation(LibrarySection.travel),
        ),
        ..._grouped(records, _travelGroup),
      ],
    );
  }

  Widget _rentals() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      _heading(
        'Rentals',
        subtitle: 'Documents organised by property.',
        back: const LibraryLocation.top(),
      ),
      _search(),
      if (data!.rentals.isEmpty && data!.rentalRecords.isEmpty)
        const _StateView(message: 'No documents in this collection.'),
      ...data!.rentals.map(
        (rental) => _CollectionCard(
          title: rental.name,
          subtitle: rental.address,
          icon: Icons.home_work_outlined,
          count: rental.documentCount,
          onTap: () =>
              _open(LibraryLocation(LibrarySection.rentals, itemId: rental.id)),
        ),
      ),
      if (data!.unassignedRentals.isNotEmpty) ...[
        _subheading('Other rental documents'),
        ...data!.unassignedRentals.map(_relatedRow),
      ],
    ],
  );

  Widget _rental(String id) {
    final rental = data!.rentals.where((x) => x.id == id).firstOrNull;
    if (rental == null) {
      return const _StateView(
        message: 'You no longer have access to this item.',
      );
    }
    final records = data!.rentalRecords.where((x) => x.parentId == id).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _heading(
          rental.name,
          subtitle: rental.address,
          back: const LibraryLocation(LibrarySection.rentals),
        ),
        ..._grouped(records, _rentalGroup),
      ],
    );
  }

  List<Widget> _grouped(
    List<LibraryRelatedDocument> records,
    String Function(String) label,
  ) {
    final groups = <String, List<LibraryRelatedDocument>>{};
    for (final record in records) {
      groups.putIfAbsent(label(record.kind), () => []).add(record);
    }
    if (groups.isEmpty) {
      return [const _StateView(message: 'No documents in this collection.')];
    }
    return [
      for (final entry in groups.entries) ...[
        _subheading(entry.key),
        ...entry.value.map(_relatedRow),
      ],
    ];
  }

  Widget _relatedRow(LibraryRelatedDocument record) => ListTile(
    contentPadding: EdgeInsets.zero,
    leading: const Icon(Icons.description_outlined),
    title: Text(record.title),
    trailing: const Icon(Icons.chevron_right),
    onTap: () => _open(
      LibraryLocation(LibrarySection.documents, itemId: record.documentId),
    ),
  );

  Widget _links() {
    final links = data!.links
        .where(
          (link) =>
              linkCategoryFilter == null ||
              link.categoryId == linkCategoryFilter,
        )
        .toList();
    final groups = <String, List<LibraryLink>>{};
    for (final link in links) {
      groups.putIfAbsent(link.category, () => []).add(link);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _heading(
          'Saved Links',
          subtitle: 'Useful links grouped by category.',
          back: const LibraryLocation.top(),
        ),
        _search(),
        DropdownButton<String?>(
          key: const ValueKey('link-category-filter'),
          value: linkCategoryFilter,
          hint: const Text('All categories'),
          items: [
            const DropdownMenuItem(value: null, child: Text('All categories')),
            ...data!.linkCategories.map(
              (c) => DropdownMenuItem(value: c.id, child: Text(c.name)),
            ),
          ],
          onChanged: (value) => setState(() => linkCategoryFilter = value),
        ),
        if (links.isEmpty)
          _StateView(
            message: search.text.isNotEmpty
                ? 'Nothing matched your search.'
                : 'No documents in this collection.',
          ),
        for (final entry in groups.entries) ...[
          _subheading(entry.key),
          ...entry.value.map(
            (link) => ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.link),
              title: Text(link.title),
              subtitle: Text(link.domain),
              trailing: TextButton(
                onPressed: () => _safeOpen(link.url),
                child: const Text('Open'),
              ),
            ),
          ),
        ],
      ],
    );
  }

  Future<void> _safeOpen(String url) async {
    final hostname = publicHttpsHostname(url);
    if (hostname == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('This link could not be opened safely.'),
          ),
        );
      }
      return;
    }
    final approved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Open external website?'),
        content: Text('You are leaving FamilyDocuments for $hostname.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Open'),
          ),
        ],
      ),
    );
    if (approved != true || !mounted) return;
    final opened = await (widget.linkOpener ?? openExternalLink)(url);
    if (!opened && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('This link could not be opened safely.')),
      );
    }
  }

  Widget _subheading(String value) => Padding(
    padding: const EdgeInsets.only(top: 24, bottom: 8),
    child: Text(
      value,
      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
    ),
  );
}

class _CollectionCard extends StatelessWidget {
  const _CollectionCard({
    required this.title,
    required this.icon,
    required this.count,
    required this.onTap,
    this.subtitle,
  });
  final String title;
  final String? subtitle;
  final IconData icon;
  final int count;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Card.outlined(
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            CircleAvatar(
              backgroundColor: const Color(0xffe5f1ee),
              child: Icon(icon, color: const Color(0xff245b52)),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (subtitle?.isNotEmpty ?? false)
                    Text(
                      subtitle!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                ],
              ),
            ),
            Text('$count'),
            const SizedBox(width: 4),
            const Icon(Icons.chevron_right),
          ],
        ),
      ),
    ),
  );
}

class _DocumentRow extends StatelessWidget {
  const _DocumentRow({required this.document, required this.onTap});
  final LibraryDocument document;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => ListTile(
    key: ValueKey('library-document-${document.id}'),
    contentPadding: const EdgeInsets.symmetric(vertical: 6),
    leading: const CircleAvatar(child: Icon(Icons.description_outlined)),
    title: Text(document.title),
    subtitle: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('${document.category} · ${_date(document.savedAt)}'),
        if (document.tags.isNotEmpty)
          Text(
            document.tags.join(' · '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        if (document.processingStatus case final status?
            when {
              'queued',
              'retry_wait',
              'processing',
              'failed',
              'permanent_failed',
            }.contains(status))
          Text(
            _status(status),
            style: const TextStyle(
              color: Color(0xff8a5a13),
              fontWeight: FontWeight.w600,
            ),
          ),
      ],
    ),
    trailing: const Icon(Icons.chevron_right),
    onTap: onTap,
  );
}

class _DetailLine extends StatelessWidget {
  const _DetailLine(this.label, this.value);
  final String label, value;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 120,
          child: Text(
            label,
            style: const TextStyle(
              color: Color(0xff657083),
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        Expanded(child: Text(value)),
      ],
    ),
  );
}

class _StateView extends StatelessWidget {
  const _StateView({required this.message, this.action});
  final String message;
  final Widget? action;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 64),
    child: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(message, textAlign: TextAlign.center),
          ?action,
        ],
      ),
    ),
  );
}

class _InlineError extends StatelessWidget {
  const _InlineError(this.message, this.retry);
  final String message;
  final VoidCallback retry;
  @override
  Widget build(BuildContext context) => Material(
    color: const Color(0xffffeeee),
    borderRadius: BorderRadius.circular(10),
    child: ListTile(
      leading: const Icon(Icons.error_outline),
      title: Text(message),
      trailing: TextButton(onPressed: retry, child: const Text('Retry')),
    ),
  );
}

String _date(DateTime value) => '${value.day}/${value.month}/${value.year}';
String _fileType(String value) => switch (value) {
  'application/pdf' => 'PDF',
  'image/jpeg' => 'JPEG image',
  'image/png' => 'PNG image',
  _ => 'Document',
};
String _status(String value) => switch (value) {
  'queued' || 'retry_wait' => 'Queued',
  'processing' => 'Reading',
  'failed' || 'permanent_failed' => 'Reading failed',
  _ => value,
};
String _travelGroup(String value) => switch (value) {
  'flight' => 'Flights',
  'accommodation' => 'Accommodation',
  'insurance' => 'Insurance',
  'passport' || 'visa' => 'Passports and visas',
  'activity' => 'Activities',
  _ => 'Other documents',
};
String _rentalGroup(String value) => switch (value) {
  'tenancy_agreement' => 'Tenancy agreements',
  'inspection' => 'Inspection reports',
  'rent' => 'Rent records',
  'maintenance' || 'repairs' => 'Maintenance',
  'tenant_communication' => 'Tenant communication',
  'insurance' => 'Insurance',
  _ => 'Other documents',
};

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
