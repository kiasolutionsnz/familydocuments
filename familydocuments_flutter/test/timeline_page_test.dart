import 'dart:async';

import 'package:familydocuments_flutter/core/auth/auth_service.dart';
import 'package:familydocuments_flutter/core/home/home_service.dart';
import 'package:familydocuments_flutter/features/timeline/data/timeline_service.dart';
import 'package:familydocuments_flutter/features/timeline/models/timeline_item.dart';
import 'package:familydocuments_flutter/features/timeline/timeline_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeTimelineService extends TimelineService {
  FakeTimelineService({List<TimelineItem>? items})
    : pages = [TimelinePageData(items: items ?? const [], hasMore: false)],
      super(FakeAuth());

  FakeTimelineService.pages(this.pages) : super(FakeAuth());

  final List<TimelinePageData> pages;
  final List<String> queries = [];
  int calls = 0;
  Object? failure;

  @override
  Future<TimelinePageData> load({
    String query = '',
    TimelineCursor? cursor,
    int limit = 40,
  }) async {
    calls++;
    queries.add(query);
    if (failure case final failure?) throw failure;
    final page = cursor == null ? 0 : 1;
    final result = pages[page.clamp(0, pages.length - 1)];
    if (query.trim().isEmpty) return result;
    return TimelinePageData(
      items: result.items.where((item) => item.matchesSearch(query)).toList(),
      hasMore: false,
    );
  }
}

class FakeAuth extends AuthService {}

class BlockingTimelineService extends TimelineService {
  BlockingTimelineService() : super(FakeAuth());
  final first = Completer<TimelinePageData>();
  int calls = 0;
  bool inFlight = false;
  bool overlapped = false;

  @override
  Future<TimelinePageData> load({
    String query = '',
    TimelineCursor? cursor,
    int limit = 40,
  }) async {
    calls++;
    if (inFlight) overlapped = true;
    inFlight = true;
    final result = calls == 1
        ? await first.future
        : const TimelinePageData(items: [], hasMore: false);
    inFlight = false;
    return result;
  }
}

TimelineItem item(
  String id,
  TimelineItemKind kind,
  DateTime when, {
  String? jobId,
  String? status,
  String? category,
  List<String> tags = const [],
  String? title,
  String? context,
  String? url,
}) => TimelineItem(
  id: id,
  eventKey: '$kind:$id',
  kind: kind,
  eventType: '${kind.name}_event',
  title: title ?? '$id title',
  context: context ?? category ?? '${kind.name} context',
  occurredAt: when,
  documentId: kind == TimelineItemKind.document ? 'document-$id' : null,
  jobId: jobId,
  status: status,
  category: category,
  tags: tags,
  url:
      url ??
      (kind == TimelineItemKind.link ? 'https://example.test/$id' : null),
  retryAllowed: status == 'failed',
);

Widget timelineHarness(
  TimelineService service, {
  List<AnalysisJob> jobs = const [],
  Future<void> Function()? refresh,
  Future<void> Function(String)? retry,
  Future<void> Function(String)? save,
  Future<void> Function(String)? choose,
  Future<void> Function(String)? dismiss,
}) => MaterialApp(
  home: Scaffold(
    body: TimelinePage(
      service: service,
      processingJobs: jobs,
      onRefreshProcessing: refresh ?? () async {},
      onRetryJob: retry ?? (_) async {},
      onSaveWithoutReading: save ?? (_) async {},
      onChooseCategory: choose ?? (_) async {},
      onDismissJob: dismiss ?? (_) async {},
    ),
  ),
);

void main() {
  final now = DateTime.now();

  testWidgets('mixed real items are newest first and grouped by date', (
    t,
  ) async {
    final service = FakeTimelineService(
      items: [
        item(
          'older',
          TimelineItemKind.link,
          now.subtract(const Duration(days: 2)),
        ),
        item('today', TimelineItemKind.document, now),
        item(
          'yesterday',
          TimelineItemKind.message,
          now.subtract(const Duration(days: 1)),
        ),
        item(
          'reminder',
          TimelineItemKind.reminder,
          now.subtract(const Duration(minutes: 1)),
        ),
      ],
    );
    await t.pumpWidget(timelineHarness(service));
    await t.pumpAndSettle();
    expect(find.text('Today'), findsOneWidget);
    expect(find.text('Yesterday'), findsOneWidget);
    expect(find.text('older title'), findsOneWidget);
    expect(
      t.getTopLeft(find.text('today title')).dy,
      lessThan(t.getTopLeft(find.text('reminder title')).dy),
    );
    expect(
      t.getTopLeft(find.text('reminder title')).dy,
      lessThan(t.getTopLeft(find.text('yesterday title')).dy),
    );
  });

  testWidgets('all five filters operate on real item kinds', (t) async {
    final service = FakeTimelineService(
      items: TimelineItemKind.values
          .map((kind) => item(kind.name, kind, now))
          .toList(),
    );
    await t.pumpWidget(timelineHarness(service));
    await t.pumpAndSettle();
    for (final label in ['Documents', 'Links', 'Messages', 'Reminders']) {
      await t.tap(find.text(label));
      await t.pump();
      final expected = label
          .toLowerCase()
          .replaceAll('documents', 'document')
          .replaceAll('links', 'link')
          .replaceAll('messages', 'message')
          .replaceAll('reminders', 'reminder');
      expect(find.text('$expected title'), findsOneWidget);
      expect(find.text('$expected title'), findsOneWidget);
    }
    await t.tap(find.text('All'));
    await t.pump();
    for (final kind in TimelineItemKind.values) {
      expect(
        find.byKey(ValueKey('timeline-item-$kind:${kind.name}')),
        findsOneWidget,
      );
    }
  });

  testWidgets('search is debounced and clearing restores Timeline', (t) async {
    final service = FakeTimelineService(
      items: [
        item('passport', TimelineItemKind.document, now),
        item(
          'invoice',
          TimelineItemKind.document,
          now.subtract(const Duration(minutes: 1)),
        ),
      ],
    );
    await t.pumpWidget(timelineHarness(service));
    await t.pumpAndSettle();
    await t.enterText(
      find.byKey(const ValueKey('timeline-search')),
      'passport',
    );
    await t.pump(const Duration(milliseconds: 349));
    expect(service.calls, 1);
    await t.pump(const Duration(milliseconds: 1));
    await t.pump();
    expect(service.queries.last, 'passport');
    expect(find.text('passport title'), findsOneWidget);
    expect(find.text('invoice title'), findsNothing);
    await t.tap(find.byTooltip('Clear Timeline search'));
    await t.pumpAndSettle();
    expect(service.queries.last, '');
    expect(find.text('invoice title'), findsOneWidget);
  });

  testWidgets('Timeline search is exact metadata filtering, not semantic', (
    t,
  ) async {
    final service = FakeTimelineService(
      items: [
        item(
          'passport',
          TimelineItemKind.document,
          now,
          title: 'Family passport saved',
          category: 'Travel Documents',
          tags: const ['identity', 'fiji'],
        ),
        item(
          'insurance',
          TimelineItemKind.document,
          now.subtract(const Duration(minutes: 1)),
          title: 'Semantically related insurance summary',
          tags: const ['policy'],
        ),
        item(
          'reference',
          TimelineItemKind.link,
          now.subtract(const Duration(minutes: 2)),
          title: 'Wellington tenancy guide saved',
          category: 'Research',
          url: 'https://tenancy.example.test/guide',
        ),
      ],
    );
    await t.pumpWidget(timelineHarness(service));
    await t.pumpAndSettle();

    Future<void> searchFor(String query) async {
      await t.enterText(find.byKey(const ValueKey('timeline-search')), query);
      await t.pump(const Duration(milliseconds: 350));
      await t.pump();
    }

    await searchFor('  TRAVEL   DOCUMENTS  ');
    expect(find.text('Family passport saved'), findsOneWidget);
    await searchFor('fiji');
    expect(find.text('Family passport saved'), findsOneWidget);
    await searchFor('tenancy.example.test');
    expect(find.text('Wellington tenancy guide saved'), findsOneWidget);
    await searchFor('revoked passport');
    expect(find.text('Nothing matched your search.'), findsOneWidget);
    expect(find.text('Semantically related insurance summary'), findsNothing);
    await t.tap(find.byTooltip('Clear Timeline search'));
    await t.pumpAndSettle();
    expect(find.text('Family passport saved'), findsOneWidget);
    expect(find.text('Semantically related insurance summary'), findsOneWidget);
  });

  testWidgets('search preserves the selected type filter', (t) async {
    final service = FakeTimelineService(
      items: [
        item(
          'shared-doc',
          TimelineItemKind.document,
          now,
          title: 'Shared record saved',
        ),
        item(
          'shared-link',
          TimelineItemKind.link,
          now.subtract(const Duration(minutes: 1)),
          title: 'Shared record saved',
        ),
      ],
    );
    await t.pumpWidget(timelineHarness(service));
    await t.pumpAndSettle();
    await t.tap(find.text('Links'));
    await t.enterText(
      find.byKey(const ValueKey('timeline-search')),
      'shared record',
    );
    await t.pump(const Duration(milliseconds: 350));
    await t.pump();
    expect(
      find.byKey(
        const ValueKey('timeline-item-TimelineItemKind.link:shared-link'),
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(
        const ValueKey('timeline-item-TimelineItemKind.document:shared-doc'),
      ),
      findsNothing,
    );
  });

  testWidgets('nonmatching restored OCR jobs do not leak into search results', (
    t,
  ) async {
    await t.pumpWidget(
      timelineHarness(
        FakeTimelineService(),
        jobs: const [
          AnalysisJob(
            id: 'job-1',
            documentId: 'document-1',
            status: 'succeeded',
            result: OrganisedDocument(
              title: 'Insurance summary',
              category: 'Documents',
              tags: ['policy'],
              pageCount: 1,
            ),
          ),
        ],
      ),
    );
    await t.pumpAndSettle();
    await t.enterText(
      find.byKey(const ValueKey('timeline-search')),
      'missing revoked record',
    );
    await t.pump(const Duration(milliseconds: 350));
    await t.pump();
    expect(find.text('Nothing matched your search.'), findsOneWidget);
    expect(find.text('Finished reading Insurance summary'), findsNothing);
  });

  testWidgets('empty, filtered-empty and search-empty states are clear', (
    t,
  ) async {
    final empty = FakeTimelineService();
    await t.pumpWidget(timelineHarness(empty));
    await t.pumpAndSettle();
    expect(find.text('Nothing has been saved yet.'), findsOneWidget);

    final documents = FakeTimelineService(
      items: [item('doc', TimelineItemKind.document, now)],
    );
    await t.pumpWidget(timelineHarness(documents));
    await t.pumpAndSettle();
    await t.tap(find.text('Links'));
    await t.pump();
    expect(find.text('Nothing matched this filter.'), findsOneWidget);
    await t.enterText(find.byKey(const ValueKey('timeline-search')), 'missing');
    await t.pump(const Duration(milliseconds: 400));
    await t.pump();
    expect(find.text('Nothing matched your search.'), findsOneWidget);
  });

  testWidgets('network error has a working Retry action', (t) async {
    final service = FakeTimelineService(
      items: [item('restored', TimelineItemKind.document, now)],
    )..failure = const TimelineServiceException('Synthetic network error.');
    await t.pumpWidget(timelineHarness(service));
    await t.pumpAndSettle();
    expect(find.text('Synthetic network error.'), findsOneWidget);
    service.failure = null;
    await t.tap(find.text('Retry'));
    await t.pumpAndSettle();
    expect(find.text('restored title'), findsOneWidget);
  });

  testWidgets('mobile pull-to-refresh refreshes jobs and Timeline', (t) async {
    await t.binding.setSurfaceSize(const Size(390, 800));
    addTearDown(() => t.binding.setSurfaceSize(null));
    var processingRefreshes = 0;
    final service = FakeTimelineService(
      items: [item('doc', TimelineItemKind.document, now)],
    );
    await t.pumpWidget(
      timelineHarness(service, refresh: () async => processingRefreshes++),
    );
    await t.pumpAndSettle();
    await t.drag(
      find.byKey(const ValueKey('timeline-list')),
      const Offset(0, 350),
    );
    await t.pumpAndSettle();
    expect(processingRefreshes, 1);
    expect(service.calls, 2);
  });

  testWidgets('pagination appends results and prevents duplicates', (t) async {
    final first = item('first', TimelineItemKind.document, now);
    final second = item(
      'second',
      TimelineItemKind.link,
      now.subtract(const Duration(minutes: 1)),
    );
    final service = FakeTimelineService.pages([
      TimelinePageData(
        items: [first],
        hasMore: true,
        nextCursor: TimelineCursor(
          occurredAt: first.occurredAt,
          key: first.eventKey,
        ),
      ),
      TimelinePageData(items: [first, second], hasMore: false),
    ]);
    await t.pumpWidget(timelineHarness(service));
    await t.pumpAndSettle();
    await t.tap(find.text('Load more'));
    await t.pumpAndSettle();
    expect(find.text('first title'), findsOneWidget);
    expect(find.text('second title'), findsOneWidget);
    expect(
      find.byKey(ValueKey('timeline-item-${first.eventKey}')),
      findsOneWidget,
    );
    expect(
      find.byKey(ValueKey('timeline-item-${second.eventKey}')),
      findsOneWidget,
    );
  });

  testWidgets('concurrent refreshes never overlap Timeline requests', (
    t,
  ) async {
    final service = BlockingTimelineService();
    await t.pumpWidget(timelineHarness(service));
    await t.pump();
    final state = t.state<TimelinePageState>(find.byType(TimelinePage));
    unawaited(state.refresh());
    unawaited(state.refresh());
    await t.pump();
    expect(service.calls, 1);
    service.first.complete(const TimelinePageData(items: [], hasMore: false));
    await t.pump();
    await t.pump();
    expect(service.calls, 2);
    expect(service.overlapped, isFalse);
  });

  testWidgets(
    'active OCR appears and updates the existing item on completion',
    (t) async {
      final fetched = item(
        'analysis',
        TimelineItemKind.document,
        now,
        jobId: 'job-1',
        status: 'queued',
      );
      final service = FakeTimelineService(items: [fetched]);
      await t.pumpWidget(
        timelineHarness(
          service,
          jobs: const [
            AnalysisJob(
              id: 'job-1',
              documentId: 'document-1',
              status: 'processing',
              displayTitle: 'Electricity bill',
            ),
          ],
        ),
      );
      await t.pumpAndSettle();
      expect(find.text('Reading Electricity bill…'), findsOneWidget);
      await t.pumpWidget(
        timelineHarness(
          service,
          jobs: const [
            AnalysisJob(
              id: 'job-1',
              documentId: 'document-1',
              status: 'succeeded',
              result: OrganisedDocument(
                title: 'Electricity bill',
                category: 'Home',
                tags: ['invoice'],
                pageCount: 1,
              ),
            ),
          ],
        ),
      );
      await t.pumpAndSettle();
      expect(find.text('Finished reading Electricity bill'), findsOneWidget);
      expect(
        find.byKey(
          const ValueKey('timeline-item-TimelineItemKind.document:analysis'),
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets('failed OCR exposes all existing recovery actions', (t) async {
    var retry = 0, save = 0, choose = 0, dismiss = 0;
    final service = FakeTimelineService(
      items: [
        item(
          'failed',
          TimelineItemKind.document,
          now,
          jobId: 'job-1',
          status: 'failed',
        ),
      ],
    );
    Future<void> openAndTap(WidgetTester tester, String label) async {
      await tester.tap(find.text('I couldn’t read this document.'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
    }

    final harness = timelineHarness(
      service,
      jobs: const [
        AnalysisJob(
          id: 'job-1',
          documentId: 'document-1',
          status: 'failed',
          retryAllowed: true,
        ),
      ],
      retry: (_) async => retry++,
      save: (_) async => save++,
      choose: (_) async => choose++,
      dismiss: (_) async => dismiss++,
    );
    await t.pumpWidget(harness);
    await t.pumpAndSettle();
    await openAndTap(t, 'Retry reading');
    await openAndTap(t, 'Save without reading');
    await openAndTap(t, 'Choose category');
    await openAndTap(t, 'Dismiss');
    expect([retry, save, choose, dismiss], [1, 1, 1, 1]);
  });

  testWidgets('selecting each supported item opens a real-data detail', (
    t,
  ) async {
    final service = FakeTimelineService(
      items: TimelineItemKind.values
          .map((kind) => item(kind.name, kind, now))
          .toList(),
    );
    await t.pumpWidget(timelineHarness(service));
    await t.pumpAndSettle();
    for (final kind in TimelineItemKind.values) {
      await t.tap(find.text('${kind.name} title'));
      await t.pumpAndSettle();
      expect(find.text('${kind.name} context'), findsWidgets);
      await t.tap(find.text('Close'));
      await t.pumpAndSettle();
    }
  });

  testWidgets(
    'mobile and desktop layouts expose appropriate refresh controls',
    (t) async {
      final service = FakeTimelineService(
        items: [item('doc', TimelineItemKind.document, now)],
      );
      await t.binding.setSurfaceSize(const Size(390, 800));
      await t.pumpWidget(timelineHarness(service));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('timeline-list')), findsOneWidget);
      await t.binding.setSurfaceSize(const Size(1200, 900));
      await t.pump();
      expect(find.byTooltip('Refresh Timeline'), findsOneWidget);
      addTearDown(() => t.binding.setSurfaceSize(null));
    },
  );

  testWidgets('Timeline details are centred, bounded and dismissible', (
    tester,
  ) async {
    for (final size in [
      const Size(1200, 900),
      const Size(820, 900),
      const Size(390, 800),
    ]) {
      await tester.binding.setSurfaceSize(size);
      await tester.pumpWidget(
        timelineHarness(
          FakeTimelineService(
            items: [item('dialog', TimelineItemKind.document, now)],
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('dialog title'));
      await tester.pumpAndSettle();
      final dialog = find.byKey(const ValueKey('timeline-detail-dialog'));
      expect(dialog, findsOneWidget);
      final rect = tester.getRect(dialog);
      expect(rect.width, lessThanOrEqualTo(620));
      expect(rect.height, lessThanOrEqualTo(size.height * .86 + 1));
      expect((rect.center.dx - size.width / 2).abs(), lessThan(2));
      expect(find.byTooltip('Close details'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('timeline-detail-scroll')),
        findsOneWidget,
      );
      expect(find.bySemanticsLabel('Timeline item details'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(dialog, findsNothing);
    }
    addTearDown(() => tester.binding.setSurfaceSize(null));
  });
}
