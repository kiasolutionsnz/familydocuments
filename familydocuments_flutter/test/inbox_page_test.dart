import 'dart:async';

import 'package:familydocuments_flutter/core/auth/auth_service.dart';
import 'package:familydocuments_flutter/features/inbox/data/inbox_service.dart';
import 'package:familydocuments_flutter/features/inbox/inbox_navigation.dart';
import 'package:familydocuments_flutter/features/inbox/inbox_page.dart';
import 'package:familydocuments_flutter/features/inbox/models/inbox_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Auth extends AuthService {}

final _now = DateTime(2027, 1, 20, 14);

InboxItem _item(
  String id,
  String subject, {
  String state = 'unreviewed',
  int attachments = 0,
  int links = 0,
}) => InboxItem(
  id: id,
  sender: '$id@example.test',
  subject: subject,
  receivedAt: id == 'new' ? _now : _now.subtract(const Duration(days: 2)),
  source: id == 'chat' ? 'Chat' : 'Email',
  preview: 'Safe preview for $subject',
  attachmentCount: attachments,
  linkCount: links,
  reviewState: state,
  updatedAt: _now,
  actions: const [],
);

class _Service extends InboxService {
  _Service({this.canEdit = true}) : super(_Auth());
  final bool canEdit;
  String lastQuery = '';
  InboxFilter lastFilter = InboxFilter.all;
  String? reviewState;
  int saveCalls = 0;

  final all = [
    _item('new', 'Travel insurance invoice', attachments: 1, links: 1),
    _item('chat', 'Family chat note', state: 'reviewed'),
  ];

  @override
  Future<InboxData> load({
    String query = '',
    InboxFilter filter = InboxFilter.all,
    int limit = 30,
    int offset = 0,
  }) async {
    lastQuery = query;
    lastFilter = filter;
    var items = all
        .where(
          (item) =>
              query.trim().isEmpty ||
              '${item.sender} ${item.subject} ${item.preview}'
                  .toLowerCase()
                  .contains(query.trim().toLowerCase()),
        )
        .toList();
    items = switch (filter) {
      InboxFilter.all => items,
      InboxFilter.unreviewed =>
        items.where((x) => x.reviewState == 'unreviewed').toList(),
      InboxFilter.attachments =>
        items.where((x) => x.attachmentCount > 0).toList(),
      InboxFilter.links => items.where((x) => x.linkCount > 0).toList(),
      InboxFilter.reviewed =>
        items.where((x) => x.reviewState == 'reviewed').toList(),
    };
    return InboxData(
      canEdit: canEdit,
      total: items.length,
      items: items,
      categories: const [InboxCategory(id: 'finance', name: 'Finance')],
      tags: const ['invoice'],
      linkCategories: const [InboxCategory(id: 'research', name: 'Research')],
    );
  }

  @override
  Future<InboxMessage> detail(String id) async => InboxMessage(
    id: id,
    sender: '$id@example.test',
    recipients: const ['family@example.test'],
    subject: id == 'new' ? 'Travel insurance invoice' : 'Family chat note',
    receivedAt: _now,
    source: id == 'chat' ? 'Chat' : 'Email',
    bodyText: '<script>not executed</script> Safe message text.',
    reviewState: reviewState ?? 'unreviewed',
    updatedAt: _now,
    canEdit: canEdit,
    attachments: id == 'new'
        ? const [
            InboxAttachment(
              id: 'attachment-1',
              fileName: 'invoice.pdf',
              mimeType: 'application/pdf',
              sizeBytes: 200,
              status: 'clean',
            ),
          ]
        : const [],
    links: id == 'new' ? const ['https://example.test/policy'] : const [],
    actions: const [],
  );

  @override
  Future<void> setReviewState(InboxMessage message, String state) async {
    reviewState = state;
  }

  @override
  Future<InboxActionResult> saveAttachment({
    required String messageId,
    required String attachmentId,
    required String categoryId,
    required List<String> tags,
    required bool requestOcr,
    required String requestId,
  }) async {
    saveCalls++;
    return InboxActionResult(
      documentId: 'document-1',
      jobId: requestOcr ? 'job-1' : null,
    );
  }
}

class _Navigation implements InboxNavigation {
  InboxLocation value = const InboxLocation();
  final controller = StreamController<InboxLocation>.broadcast();
  @override
  InboxLocation get current => value;
  @override
  Stream<InboxLocation> get changes => controller.stream;
  @override
  void open(InboxLocation location) {
    value = location;
    controller.add(location);
  }

  @override
  void replace(InboxLocation location) => open(location);
  void back(InboxLocation location) => open(location);
  @override
  void dispose() => controller.close();
}

Future<void> _pump(
  WidgetTester tester,
  _Service service, {
  Future<bool> Function(String)? opener,
  InboxNavigation? navigation,
  ValueChanged<InboxMessage>? onDiscuss,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: InboxPage(
          service: service,
          onDataChanged: () {},
          onOcrRequested: () async {},
          linkOpener: opener,
          navigation: navigation,
          onDiscuss: onDiscuss,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('message can establish safe conversational Inbox context', (
    tester,
  ) async {
    InboxMessage? discussed;
    await _pump(tester, _Service(), onDiscuss: (value) => discussed = value);
    await tester.tap(find.text('Travel insurance invoice'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Continue in Home'));
    expect(discussed?.subject, 'Travel insurance invoice');
  });

  testWidgets('shows newest Inbox items grouped as New and Earlier', (
    tester,
  ) async {
    await _pump(tester, _Service());
    expect(find.text('Inbox'), findsOneWidget);
    expect(find.text('New'), findsOneWidget);
    expect(find.text('Earlier'), findsOneWidget);
    expect(find.text('Travel insurance invoice'), findsOneWidget);
    expect(find.text('Family chat note'), findsOneWidget);
  });

  testWidgets(
    'predictable search shows honest empty state and clearing restores items',
    (tester) async {
      final service = _Service();
      await _pump(tester, service);
      await tester.enterText(find.byType(TextField).first, 'nothing matches');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(find.text('Nothing matched your search.'), findsOneWidget);
      await tester.enterText(find.byType(TextField).first, '');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(find.text('Travel insurance invoice'), findsOneWidget);
    },
  );

  testWidgets('filters attachment, link, reviewed and unreviewed states', (
    tester,
  ) async {
    final service = _Service();
    await _pump(tester, service);
    for (final label in [
      'With attachments',
      'With links',
      'Reviewed',
      'Unreviewed',
    ]) {
      await tester.ensureVisible(find.text(label));
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
    }
    expect(service.lastFilter, InboxFilter.unreviewed);
  });

  testWidgets(
    'detail renders message body as inert text and external link opens only when selected',
    (tester) async {
      String? opened;
      await _pump(
        tester,
        _Service(),
        opener: (url) async {
          opened = url;
          return true;
        },
      );
      await tester.tap(find.text('Travel insurance invoice'));
      await tester.pumpAndSettle();
      expect(
        find.text('<script>not executed</script> Safe message text.'),
        findsOneWidget,
      );
      expect(opened, isNull);
      await tester.tap(find.byTooltip('Open link'));
      await tester.pump();
      expect(opened, 'https://example.test/policy');
    },
  );

  testWidgets('mark reviewed uses persisted action and returns to Inbox', (
    tester,
  ) async {
    final service = _Service();
    await _pump(tester, service);
    await tester.tap(find.text('Travel insurance invoice'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mark reviewed'));
    await tester.pumpAndSettle();
    expect(service.reviewState, 'reviewed');
    expect(find.text('Inbox'), findsOneWidget);
  });

  testWidgets('read-only member sees message without mutation actions', (
    tester,
  ) async {
    await _pump(tester, _Service(canEdit: false));
    await tester.tap(find.text('Travel insurance invoice'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('only authorised Family members'),
      findsOneWidget,
    );
    expect(find.text('Mark reviewed'), findsNothing);
    expect(find.text('Save'), findsNothing);
  });

  testWidgets('attachment can save without OCR', (tester) async {
    final service = _Service();
    await _pump(tester, service);
    await tester.tap(find.text('Travel insurance invoice'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save').first);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();
    expect(service.saveCalls, 1);
  });

  testWidgets('message detail follows Inbox history and browser Back', (
    tester,
  ) async {
    final navigation = _Navigation();
    await _pump(tester, _Service(), navigation: navigation);
    await tester.tap(find.text('Travel insurance invoice'));
    await tester.pumpAndSettle();
    expect(navigation.value.messageId, 'new');
    navigation.back(const InboxLocation());
    await tester.pumpAndSettle();
    expect(find.text('New'), findsOneWidget);
  });
}
