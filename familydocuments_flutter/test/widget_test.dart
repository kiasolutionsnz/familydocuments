import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:familydocuments_flutter/main.dart';
import 'package:familydocuments_flutter/core/auth/auth_service.dart';
import 'package:familydocuments_flutter/core/auth/session_store.dart';
import 'package:familydocuments_flutter/core/home/home_service.dart';
import 'package:familydocuments_flutter/core/navigation/destination_state.dart';
import 'package:familydocuments_flutter/features/timeline/data/timeline_service.dart';
import 'package:familydocuments_flutter/features/timeline/models/timeline_item.dart';

class Store implements SessionStore {
  String? value;
  @override
  Future<void> clear() async => value = null;
  @override
  Future<String?> readRefreshToken() async => value;
  @override
  Future<void> writeRefreshToken(String v) async => value = v;
}

class Client extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest r) async {
    final b = jsonEncode({
      'access_token':
          'x.${base64Url.encode(utf8.encode(jsonEncode({'exp': DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch ~/ 1000}))).replaceAll('=', '')}.x',
      'refresh_token': 'r',
      'user': {'id': 'u', 'email': 'ava@example.com'},
    });
    return http.StreamedResponse(Stream.value(utf8.encode(b)), 200, request: r);
  }
}

class FakeAuth extends AuthService {
  FakeAuth(this.current);
  Session? current;
  bool signedOut = false;
  @override
  Session? get session => current;
  @override
  Future<Session?> restore() async => current;
  @override
  Future<void> signOut() async {
    signedOut = true;
    current = null;
  }
}

class FakeHomeService extends HomeService {
  FakeHomeService(
    super.auth, {
    this.failFirstReminder = false,
    List<AnalysisJob> pendingJobs = const [],
    List<String> categories = const ['Documents', 'Home'],
    List<SavedLinkCategory> linkCategories = const [
      SavedLinkCategory(id: 'links-research', name: 'Research'),
      SavedLinkCategory(id: 'links-travel', name: 'Travel ideas'),
    ],
    this.pollingResult,
    this.submissionResult,
    this.failFirstAnalysisSubmit = false,
  }) : pendingJobs = List.of(pendingJobs),
       categoryNames = List.of(categories),
       savedLinkCategories = List.of(linkCategories);
  int reminderCalls = 0;
  final bool failFirstReminder;
  final List<AnalysisJob> pendingJobs;
  final List<String> categoryNames;
  final List<SavedLinkCategory> savedLinkCategories;
  final AnalysisJob? pollingResult;
  final AnalysisJob? submissionResult;
  final bool failFirstAnalysisSubmit;
  int dismissCalls = 0;
  int saveCalls = 0;
  int analysisCalls = 0;
  int createCategoryCalls = 0;
  int categorizeCalls = 0;
  int restoreCalls = 0;
  int retryAnalysisCalls = 0;
  int pollCalls = 0;
  int linkSaveCalls = 0;
  int linkCategoryCreateCalls = 0;
  String? savedCategory;
  String? savedLinkUrl;
  String? savedLinkTitle;
  Uint8List? savedBytes;
  final List<String> analysisRequestIds = [];
  final List<String> reminderRequestIds = [];
  @override
  Future<List<AnalysisJob>> pendingAnalysisJobs() async {
    restoreCalls++;
    return List.of(pendingJobs);
  }

  @override
  Future<void> dismissAnalysisJob(String id) async {
    dismissCalls++;
    pendingJobs.removeWhere((job) => job.id == id);
  }

  @override
  Future<List<String>> categories() async => List.of(categoryNames);

  @override
  Future<List<SavedLinkCategory>> linkCategories() async =>
      List.of(savedLinkCategories);

  @override
  Future<SavedLinkCategory> createLinkCategory(String name) async {
    linkCategoryCreateCalls++;
    final category = SavedLinkCategory(
      id: 'links-${savedLinkCategories.length + 1}',
      name: name,
    );
    savedLinkCategories.add(category);
    return category;
  }

  @override
  Future<SavedLinkResult> saveLink({
    required String url,
    required String title,
    required SavedLinkCategory category,
  }) async {
    linkSaveCalls++;
    savedLinkUrl = url;
    savedLinkTitle = title;
    savedCategory = category.name;
    return SavedLinkResult(
      id: 'saved-link-1',
      title: title,
      category: category.name,
      duplicate: false,
    );
  }

  @override
  Future<CategoryResolution> resolveCategory(String requested) async =>
      resolveCategoryName(requested, categoryNames);

  @override
  Future<String> createCategory(String requested) async {
    final name = canonicalCategoryName(requested);
    final existing = resolveCategoryName(name, categoryNames);
    if (existing.type == CategoryResolutionType.found) {
      return existing.category!;
    }
    createCategoryCalls++;
    categoryNames.add(name);
    return name;
  }

  @override
  Future<OrganisedDocument> saveUpload({
    required String name,
    required String mimeType,
    required Uint8List bytes,
    required String category,
  }) async {
    saveCalls++;
    savedCategory = category;
    savedBytes = bytes;
    return OrganisedDocument(
      title: name.replaceFirst('.pdf', ''),
      category: category,
      tags: const [],
      pageCount: 0,
    );
  }

  @override
  Future<AnalysisJob> submitAnalysisJob({
    required String name,
    required String mimeType,
    required Uint8List bytes,
    required bool invoice,
    required String idempotencyKey,
  }) async {
    analysisCalls++;
    analysisRequestIds.add(idempotencyKey);
    if (failFirstAnalysisSubmit && analysisCalls == 1) {
      throw HomeServiceException(
        'Your document could not be queued. Try again.',
      );
    }
    savedBytes = bytes;
    return submissionResult ??
        const AnalysisJob(
          id: 'job-1',
          documentId: 'document-1',
          status: 'queued',
        );
  }

  @override
  Future<AnalysisJob> analysisJob(String id) async {
    pollCalls++;
    return pollingResult ??
        const AnalysisJob(
          id: 'job-1',
          documentId: 'document-1',
          status: 'processing',
        );
  }

  @override
  Future<AnalysisJob> retryAnalysisJob(String id) async {
    retryAnalysisCalls++;
    return const AnalysisJob(
      id: 'job-1',
      documentId: 'document-1',
      status: 'queued',
    );
  }

  @override
  Future<void> categorizeAnalysisJob(String id, String category) async {
    categorizeCalls++;
    pendingJobs.removeWhere((job) => job.id == id);
  }

  @override
  Future<ReminderResult> createReminder({
    required String title,
    required String dueDate,
    String? dueTime,
    required String requestId,
    String? documentId,
  }) async {
    reminderCalls++;
    reminderRequestIds.add(requestId);
    if (failFirstReminder && reminderCalls == 1) {
      throw HomeServiceException(
        'Your reminder could not be added. Try again.',
      );
    }
    return ReminderResult(
      id: 'reminder-1',
      title: title,
      dueDate: dueDate,
      dueTime: dueTime,
    );
  }
}

class FakeTimelineService extends TimelineService {
  FakeTimelineService(super.auth, {this.timelineItems = const []});
  final List<TimelineItem> timelineItems;
  int calls = 0;

  @override
  Future<TimelinePageData> load({
    String query = '',
    TimelineCursor? cursor,
    int limit = 40,
  }) async {
    calls++;
    return TimelinePageData(items: timelineItems, hasMore: false);
  }
}

class FakeDestinationState implements DestinationState {
  FakeDestinationState([this.value = PrimaryDestination.home]);

  PrimaryDestination value;
  final controller = StreamController<PrimaryDestination>.broadcast();

  @override
  PrimaryDestination get current => value;

  @override
  Stream<PrimaryDestination> get changes => controller.stream;

  @override
  void select(PrimaryDestination destination) {
    value = destination;
  }

  void simulateHistory(PrimaryDestination destination) {
    value = destination;
    controller.add(destination);
  }

  @override
  void reset() => value = PrimaryDestination.home;

  @override
  void dispose() => controller.close();
}

FakeAuth authenticatedUser() => FakeAuth(
  Session(
    accessToken: 'access',
    refreshToken: 'refresh',
    email: 'ava@example.com',
    userId: 'u',
  ),
);

SelectedUpload syntheticUpload([String name = 'synthetic-rental.pdf']) =>
    SelectedUpload(name: name, bytes: Uint8List.fromList([1, 2, 3, 4]));

Future<void> attachAndSend(WidgetTester tester, String message) async {
  await tester.pump(const Duration(milliseconds: 100));
  await tester.tap(find.byTooltip('Attach a document').last);
  await tester.pump();
  await tester.enterText(find.byType(TextField).last, message);
  await tester.tap(find.byTooltip('Send').last);
  await tester.pump();
}

void main() {
  test('invalid destination paths fall back to Home', () {
    expect(destinationFromPath('#/not-a-screen'), PrimaryDestination.home);
  });

  testWidgets('Timeline destination survives an authenticated app rebuild', (
    t,
  ) async {
    final destination = FakeDestinationState(PrimaryDestination.timeline);
    final auth = authenticatedUser();
    final timeline = FakeTimelineService(auth);
    final home = FakeHomeService(
      auth,
      pendingJobs: const [
        AnalysisJob(
          id: 'job-refresh',
          documentId: 'document-refresh',
          status: 'queued',
          displayTitle: 'Refresh test bill',
        ),
      ],
      pollingResult: const AnalysisJob(
        id: 'job-refresh',
        documentId: 'document-refresh',
        status: 'queued',
        displayTitle: 'Refresh test bill',
      ),
    );
    await t.pumpWidget(
      FamilyDocumentsApp(
        key: UniqueKey(),
        auth: auth,
        homeService: home,
        timelineService: timeline,
        destinationState: destination,
      ),
    );
    await t.pump(const Duration(milliseconds: 100));
    await t.pump();
    expect(
      find.text('Everything you’ve saved and received, newest first.'),
      findsOneWidget,
    );
    expect(find.text('Refresh test bill queued for reading'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
    await t.pumpWidget(
      FamilyDocumentsApp(
        key: UniqueKey(),
        auth: auth,
        homeService: home,
        timelineService: timeline,
        destinationState: destination,
      ),
    );
    await t.pump(const Duration(milliseconds: 100));
    await t.pump();
    expect(
      find.text('Everything you’ve saved and received, newest first.'),
      findsOneWidget,
    );
    expect(find.text('Refresh test bill queued for reading'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
    await destination.controller.close();
  });

  testWidgets('destination history changes select the matching screen', (
    t,
  ) async {
    final destination = FakeDestinationState();
    final auth = authenticatedUser();
    await t.pumpWidget(
      FamilyDocumentsApp(
        auth: auth,
        homeService: FakeHomeService(auth),
        timelineService: FakeTimelineService(auth),
        destinationState: destination,
      ),
    );
    await t.pumpAndSettle();
    destination.simulateHistory(PrimaryDestination.timeline);
    await t.pumpAndSettle();
    expect(
      find.text('Everything you’ve saved and received, newest first.'),
      findsOneWidget,
    );
    destination.simulateHistory(PrimaryDestination.home);
    await t.pumpAndSettle();
    expect(find.text('What do you need?'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
    await destination.controller.close();
  });

  testWidgets('sign-out clears the restorable authenticated destination', (
    t,
  ) async {
    final destination = FakeDestinationState(PrimaryDestination.timeline);
    final auth = authenticatedUser();
    await t.pumpWidget(
      FamilyDocumentsApp(
        auth: auth,
        homeService: FakeHomeService(auth),
        timelineService: FakeTimelineService(auth),
        destinationState: destination,
      ),
    );
    await t.pumpAndSettle();
    final menu = t.widget<PopupMenuButton<String>>(
      find.byKey(const ValueKey('profile-avatar')),
    );
    menu.onSelected!('signout');
    await t.pumpAndSettle();
    expect(destination.current, PrimaryDestination.home);
    expect(find.text('Sign in'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
    await destination.controller.close();
  });

  testWidgets('shows session check before sign in', (t) async {
    await t.pumpWidget(const FamilyDocumentsApp());
    expect(find.text('Checking your session…'), findsOneWidget);
  });
  testWidgets('avatar opens settings placeholder', (t) async {
    await t.pumpWidget(
      FamilyDocumentsApp(
        auth: AuthService(store: Store(), client: Client()),
      ),
    );
    await t.pump();
    await t.enterText(find.byType(EditableText).first, 'a');
    await t.enterText(find.byType(EditableText).last, 'p');
    await t.tap(find.text('Sign in'));
    await t.pumpAndSettle();
    expect(find.text('A'), findsWidgets);
    await t.tap(find.byKey(const ValueKey('profile-avatar')));
    await t.pumpAndSettle();
    expect(find.text('Settings'), findsOneWidget);
    await t.tap(find.text('Settings'));
    await t.pumpAndSettle();
    expect(find.text('Settings will be connected in Phase 2.'), findsOneWidget);
  });
  testWidgets('avatar sign out returns to signed-out screen', (t) async {
    final auth = FakeAuth(
      Session(
        accessToken: 'access',
        refreshToken: 'refresh',
        email: 'ava@example.com',
        userId: 'u',
      ),
    );
    await t.pumpWidget(FamilyDocumentsApp(auth: auth));
    await t.pump();
    expect(find.text('A'), findsWidgets);
    await t.tap(find.byKey(const ValueKey('profile-avatar')));
    await t.pumpAndSettle();
    await t.tap(find.text('Sign out'));
    await t.pumpAndSettle();
    expect(auth.signedOut, isTrue);
    expect(find.text('Sign in'), findsOneWidget);
  });

  testWidgets('Home creates a standalone reminder without an attachment', (
    t,
  ) async {
    final auth = FakeAuth(
      Session(
        accessToken: 'access',
        refreshToken: 'refresh',
        email: 'ava@example.com',
        userId: 'u',
      ),
    );
    final home = FakeHomeService(auth);
    await t.pumpWidget(FamilyDocumentsApp(auth: auth, homeService: home));
    await t.pump();
    await t.enterText(
      find.byType(TextField).last,
      'Remind me about doctor appointment tomorrow at 2 pm',
    );
    await t.tap(find.byTooltip('Send').last);
    await t.pumpAndSettle();
    expect(home.reminderCalls, 1);
    expect(
      find.text('Reminder added: Doctor appointment — tomorrow at 2:00 pm'),
      findsOneWidget,
    );
  });

  testWidgets('Home asks for an ambiguous reminder date', (t) async {
    final auth = FakeAuth(
      Session(
        accessToken: 'access',
        refreshToken: 'refresh',
        email: 'ava@example.com',
        userId: 'u',
      ),
    );
    final home = FakeHomeService(auth);
    await t.pumpWidget(FamilyDocumentsApp(auth: auth, homeService: home));
    await t.pump();
    await t.enterText(
      find.byType(TextField).last,
      'Remind me sometime next month',
    );
    await t.tap(find.byTooltip('Send').last);
    await t.pump();
    expect(home.reminderCalls, 0);
    expect(find.text('What date next month should I use?'), findsOneWidget);
  });

  testWidgets('reminder retry reuses its idempotency key', (t) async {
    final auth = FakeAuth(
      Session(
        accessToken: 'access',
        refreshToken: 'refresh',
        email: 'ava@example.com',
        userId: 'u',
      ),
    );
    final home = FakeHomeService(auth, failFirstReminder: true);
    await t.pumpWidget(FamilyDocumentsApp(auth: auth, homeService: home));
    await t.pump();
    await t.enterText(
      find.byType(TextField).last,
      'Remind me about doctor appointment tomorrow at 2 pm',
    );
    await t.tap(find.byTooltip('Send').last);
    await t.pumpAndSettle();
    await t.tap(find.text('Retry'));
    await t.pumpAndSettle();
    expect(home.reminderCalls, 2);
    expect(home.reminderRequestIds.toSet(), hasLength(1));
    expect(
      find.text('Reminder added: Doctor appointment — tomorrow at 2:00 pm'),
      findsOneWidget,
    );
  });

  testWidgets('pasted link is saved after a conversational category choice', (
    t,
  ) async {
    final auth = authenticatedUser();
    final home = FakeHomeService(auth);
    await t.pumpWidget(FamilyDocumentsApp(auth: auth, homeService: home));
    await t.pump();
    await t.enterText(
      find.byType(TextField).last,
      'Save this link - https://familydocuments.app/',
    );
    await t.tap(find.byTooltip('Send').last);
    await t.pumpAndSettle();
    expect(
      find.text('Which category should I save this link in?'),
      findsOneWidget,
    );
    expect(find.text('Research'), findsOneWidget);

    await t.enterText(find.byType(TextField).last, '  research  ');
    await t.tap(find.byTooltip('Send').last);
    await t.pumpAndSettle();
    expect(home.linkSaveCalls, 1);
    expect(home.savedLinkUrl, 'https://familydocuments.app/');
    expect(home.savedLinkTitle, 'familydocuments.app');
    expect(home.savedCategory, 'Research');
    expect(find.text('Saved familydocuments.app in Research.'), findsOneWidget);
  });

  testWidgets('unknown link category is confirmed in the conversation', (
    t,
  ) async {
    final auth = authenticatedUser();
    final home = FakeHomeService(auth);
    await t.pumpWidget(FamilyDocumentsApp(auth: auth, homeService: home));
    await t.pump();
    await t.enterText(
      find.byType(TextField).last,
      'https://example.com/article',
    );
    await t.tap(find.byTooltip('Send').last);
    await t.pumpAndSettle();
    await t.enterText(find.byType(TextField).last, 'Recipes for later');
    await t.tap(find.byTooltip('Send').last);
    await t.pumpAndSettle();
    expect(
      find.text(
        'I couldn’t find that link category. Would you like me to create “Recipes for later”?',
      ),
      findsOneWidget,
    );
    expect(home.linkSaveCalls, 0);

    await t.tap(find.text('Create and save'));
    await t.pumpAndSettle();
    expect(home.linkCategoryCreateCalls, 1);
    expect(home.linkSaveCalls, 1);
    expect(home.savedCategory, 'Recipes for later');
  });

  testWidgets('failed analysis can be saved without reading', (t) async {
    final auth = FakeAuth(
      Session(
        accessToken: 'access',
        refreshToken: 'refresh',
        email: 'ava@example.com',
        userId: 'u',
      ),
    );
    final home = FakeHomeService(
      auth,
      pendingJobs: const [
        AnalysisJob(
          id: 'job-1',
          documentId: 'document-1',
          status: 'permanent_failed',
          failure: 'This document could not be read.',
          retryAllowed: true,
        ),
      ],
    );
    await t.pumpWidget(FamilyDocumentsApp(auth: auth, homeService: home));
    await t.pump();
    expect(
      find.text('The file was saved, but I couldn’t read its contents.'),
      findsOneWidget,
    );
    expect(find.text('Save without reading'), findsOneWidget);
    expect(find.text('Choose category'), findsOneWidget);
    expect(find.text('Retry reading'), findsOneWidget);
    expect(find.text('Dismiss'), findsOneWidget);
    await t.tap(find.text('Save without reading'));
    await t.pumpAndSettle();
    expect(home.dismissCalls, 1);
    expect(
      find.text('Saved without reading. You can change its category later.'),
      findsOneWidget,
    );
  });

  testWidgets('existing Rentals saves selected bytes without OCR', (t) async {
    final auth = authenticatedUser();
    final home = FakeHomeService(auth, categories: const ['Home', 'Rentals']);
    await t.pumpWidget(
      FamilyDocumentsApp(
        auth: auth,
        homeService: home,
        pickUpload: () async => syntheticUpload(),
      ),
    );
    await t.pump();
    await attachAndSend(t, 'Save this as rental');
    await t.pumpAndSettle();
    expect(home.saveCalls, 1);
    expect(home.analysisCalls, 0);
    expect(home.savedCategory, 'Rentals');
    expect(home.savedBytes, orderedEquals([1, 2, 3, 4]));
    expect(find.text('Saved in Rentals.'), findsOneWidget);
  });

  testWidgets(
    'suggested destination can be changed without losing attachment',
    (t) async {
      final auth = authenticatedUser();
      final home = FakeHomeService(auth, categories: const ['Home', 'Rentals']);
      await t.pumpWidget(
        FamilyDocumentsApp(
          auth: auth,
          homeService: home,
          pickUpload: () async => syntheticUpload(),
        ),
      );
      await t.pump();
      await t.tap(find.byTooltip('Attach a document').last);
      await t.pump();
      await t.tap(find.byTooltip('Send').last);
      await t.pumpAndSettle();
      expect(find.text('Choose category'), findsOneWidget);
      await t.tap(find.text('Choose category'));
      await t.pumpAndSettle();
      await t.tap(find.text('Rentals').last);
      await t.pumpAndSettle();
      expect(home.savedCategory, 'Rentals');
      expect(home.savedBytes, orderedEquals([1, 2, 3, 4]));
      expect(home.analysisCalls, 0);
      expect(find.text('Saved in Rentals.'), findsOneWidget);
    },
  );

  testWidgets('missing Rentals offers create choose and cancel', (t) async {
    final auth = authenticatedUser();
    final home = FakeHomeService(auth, categories: const ['Home']);
    await t.pumpWidget(
      FamilyDocumentsApp(
        auth: auth,
        homeService: home,
        pickUpload: () async => syntheticUpload(),
      ),
    );
    await t.pump();
    await attachAndSend(t, 'Save this in Rentals');
    await t.pumpAndSettle();
    expect(
      find.text(
        'Your family doesn’t have a Rentals category yet. Would you like to create it?',
      ),
      findsOneWidget,
    );
    expect(find.text('Create and save'), findsOneWidget);
    expect(find.text('Choose another category'), findsOneWidget);
    expect(find.text('Cancel'), findsOneWidget);
    expect(home.saveCalls, 0);
  });

  testWidgets('create and save creates one category and saves once', (t) async {
    final auth = authenticatedUser();
    final home = FakeHomeService(auth, categories: const ['Home']);
    await t.pumpWidget(
      FamilyDocumentsApp(
        auth: auth,
        homeService: home,
        pickUpload: () async => syntheticUpload(),
      ),
    );
    await t.pump();
    await attachAndSend(t, 'Save this in rental');
    await t.pumpAndSettle();
    await t.tap(find.text('Create and save'));
    await t.pumpAndSettle();
    expect(home.createCategoryCalls, 1);
    expect(home.saveCalls, 1);
    expect(home.analysisCalls, 0);
    expect(find.text('Saved in Rentals.'), findsOneWidget);
  });

  testWidgets('choose another category saves the same selected bytes', (
    t,
  ) async {
    final auth = authenticatedUser();
    final home = FakeHomeService(auth, categories: const ['Home']);
    await t.pumpWidget(
      FamilyDocumentsApp(
        auth: auth,
        homeService: home,
        pickUpload: () async => syntheticUpload(),
      ),
    );
    await t.pump();
    await attachAndSend(t, 'Save this in Rentals');
    await t.pumpAndSettle();
    await t.tap(find.text('Choose another category'));
    await t.pumpAndSettle();
    await t.tap(find.text('Home').last);
    await t.pumpAndSettle();
    expect(home.savedCategory, 'Home');
    expect(home.savedBytes, orderedEquals([1, 2, 3, 4]));
    expect(home.analysisCalls, 0);
  });

  testWidgets('cancel keeps the attachment without false success', (t) async {
    final auth = authenticatedUser();
    final home = FakeHomeService(auth, categories: const ['Home']);
    await t.pumpWidget(
      FamilyDocumentsApp(
        auth: auth,
        homeService: home,
        pickUpload: () async => syntheticUpload(),
      ),
    );
    await t.pump();
    await attachAndSend(t, 'Save this in Rentals');
    await t.pumpAndSettle();
    await t.tap(find.text('Cancel'));
    await t.pumpAndSettle();
    expect(home.saveCalls, 0);
    expect(
      find.text('Not saved. Your document is still attached.'),
      findsOneWidget,
    );
    expect(find.text('synthetic-rental.pdf'), findsOneWidget);
  });

  testWidgets('ambiguous category requires a real selection', (t) async {
    final auth = authenticatedUser();
    final home = FakeHomeService(
      auth,
      categories: const ['Home', 'Home records'],
    );
    await t.pumpWidget(
      FamilyDocumentsApp(
        auth: auth,
        homeService: home,
        pickUpload: () async => syntheticUpload('synthetic-home.pdf'),
      ),
    );
    await t.pump();
    await attachAndSend(t, 'Save this in home records archive');
    await t.pumpAndSettle();
    expect(
      find.text(
        'I found more than one matching category. Which one should I use?',
      ),
      findsOneWidget,
    );
    expect(find.text('Create and save'), findsNothing);
    expect(find.text('Choose another category'), findsOneWidget);
    expect(home.saveCalls, 0);
  });

  testWidgets('explicit scan creates one async job and renders success', (
    t,
  ) async {
    final auth = authenticatedUser();
    final home = FakeHomeService(
      auth,
      pollingResult: const AnalysisJob(
        id: 'job-1',
        documentId: 'document-1',
        status: 'succeeded',
        result: OrganisedDocument(
          title: 'Synthetic electricity bill',
          category: 'Home',
          tags: ['invoice'],
          pageCount: 1,
        ),
      ),
    );
    await t.pumpWidget(
      FamilyDocumentsApp(
        auth: auth,
        homeService: home,
        pickUpload: () async => syntheticUpload('synthetic-bill.pdf'),
      ),
    );
    await t.pump();
    await attachAndSend(t, 'Scan this document for OCR');
    for (
      var attempt = 0;
      attempt < 5 && find.text('Synthetic electricity bill').evaluate().isEmpty;
      attempt++
    ) {
      await t.pump(const Duration(milliseconds: 500));
    }
    expect(home.analysisCalls, 1);
    expect(home.saveCalls, 0);
    expect(home.savedBytes, orderedEquals([1, 2, 3, 4]));
    expect(find.text('Finished reading your document'), findsOneWidget);
    expect(find.text('Synthetic electricity bill'), findsOneWidget);
    expect(find.text('Category'), findsOneWidget);
    expect(find.widgetWithText(Chip, 'Home'), findsOneWidget);
    expect(find.text('Tags'), findsOneWidget);
    expect(find.text('invoice'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('failed scan retry keeps the same durable document', (t) async {
    final auth = authenticatedUser();
    final home = FakeHomeService(
      auth,
      pendingJobs: const [
        AnalysisJob(
          id: 'job-1',
          documentId: 'document-1',
          status: 'permanent_failed',
          retryAllowed: true,
        ),
      ],
    );
    await t.pumpWidget(FamilyDocumentsApp(auth: auth, homeService: home));
    await t.pump();
    await t.tap(find.text('Retry reading'));
    await t.pump();
    expect(home.retryAnalysisCalls, 1);
    expect(home.analysisCalls, 0);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('failure category and dismissal create no OCR job and persist', (
    t,
  ) async {
    final auth = authenticatedUser();
    final home = FakeHomeService(
      auth,
      categories: const ['Home'],
      pendingJobs: const [
        AnalysisJob(
          id: 'job-1',
          documentId: 'document-1',
          status: 'permanent_failed',
          retryAllowed: true,
        ),
      ],
    );
    await t.pumpWidget(FamilyDocumentsApp(auth: auth, homeService: home));
    await t.pump();
    await t.tap(find.text('Choose category'));
    await t.pumpAndSettle();
    await t.tap(find.text('Home').last);
    await t.pumpAndSettle();
    expect(home.categorizeCalls, 1);
    expect(home.analysisCalls, 0);

    final dismissHome = FakeHomeService(
      auth,
      pendingJobs: const [
        AnalysisJob(
          id: 'job-2',
          documentId: 'document-2',
          status: 'permanent_failed',
          retryAllowed: true,
        ),
      ],
    );
    await t.pumpWidget(
      FamilyDocumentsApp(
        key: UniqueKey(),
        auth: auth,
        homeService: dismissHome,
      ),
    );
    await t.pump();
    await t.tap(find.text('Dismiss'));
    await t.pumpAndSettle();
    expect(dismissHome.dismissCalls, 1);
    await t.pumpWidget(
      FamilyDocumentsApp(
        key: UniqueKey(),
        auth: auth,
        homeService: dismissHome,
      ),
    );
    await t.pump();
    expect(
      find.text('The file was saved, but I couldn’t read its contents.'),
      findsNothing,
    );
    expect(dismissHome.analysisCalls, 0);
  });

  testWidgets('navigation and rebuild restore a pending job', (t) async {
    final auth = authenticatedUser();
    final home = FakeHomeService(
      auth,
      pendingJobs: const [
        AnalysisJob(
          id: 'job-1',
          documentId: 'document-1',
          status: 'processing',
        ),
      ],
    );
    await t.pumpWidget(
      FamilyDocumentsApp(key: UniqueKey(), auth: auth, homeService: home),
    );
    await t.pump(const Duration(milliseconds: 100));
    expect(
      find.text('Reading and organising your document in the background…'),
      findsOneWidget,
    );
    await t.tap(find.text('Timeline').first);
    await t.pump();
    await t.tap(find.text('Home').first);
    await t.pump();
    expect(
      find.text('Reading and organising your document in the background…'),
      findsOneWidget,
    );
    await t.pumpWidget(
      FamilyDocumentsApp(key: UniqueKey(), auth: auth, homeService: home),
    );
    await t.pump(const Duration(milliseconds: 100));
    expect(home.restoreCalls, greaterThanOrEqualTo(2));
    expect(
      find.text('Reading and organising your document in the background…'),
      findsOneWidget,
    );
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('retrying a failed submission reuses its idempotency key', (
    t,
  ) async {
    final auth = authenticatedUser();
    final home = FakeHomeService(auth, failFirstAnalysisSubmit: true);
    await t.pumpWidget(
      FamilyDocumentsApp(
        auth: auth,
        homeService: home,
        pickUpload: () async => syntheticUpload('synthetic-bill.pdf'),
      ),
    );
    await t.pump();
    await attachAndSend(t, 'Scan this document for OCR');
    await t.pumpAndSettle();
    await t.tap(find.text('Retry'));
    await t.pump();
    expect(home.analysisCalls, 2);
    expect(home.analysisRequestIds.toSet(), hasLength(1));
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('reselecting the same file reuses its OCR idempotency key', (
    t,
  ) async {
    final auth = authenticatedUser();
    final home = FakeHomeService(auth);
    await t.pumpWidget(
      FamilyDocumentsApp(
        auth: auth,
        homeService: home,
        pickUpload: () async => syntheticUpload('synthetic-bill.pdf'),
      ),
    );
    await t.pump();
    await attachAndSend(t, 'Scan this document for OCR');
    await t.pumpWidget(const SizedBox());
    await t.pumpWidget(
      FamilyDocumentsApp(
        key: UniqueKey(),
        auth: auth,
        homeService: home,
        pickUpload: () async => syntheticUpload('synthetic-bill.pdf'),
      ),
    );
    await t.pump();
    await attachAndSend(t, 'Scan this document for OCR');
    await t.pump();
    expect(home.analysisCalls, 2);
    expect(home.analysisRequestIds.toSet(), hasLength(1));
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('reused completed OCR is displayed immediately', (t) async {
    final auth = authenticatedUser();
    final home = FakeHomeService(
      auth,
      submissionResult: const AnalysisJob(
        id: 'job-existing',
        documentId: 'document-existing',
        status: 'succeeded',
        result: OrganisedDocument(
          title: 'Synthetic electricity bill',
          category: 'Finance',
          tags: ['invoice'],
          pageCount: 1,
        ),
      ),
    );
    await t.pumpWidget(
      FamilyDocumentsApp(
        auth: auth,
        homeService: home,
        pickUpload: () async => syntheticUpload('synthetic-bill.pdf'),
      ),
    );
    await t.pump();
    await attachAndSend(t, 'Scan this document for OCR');
    await t.pump();
    expect(find.text('Finished reading your document'), findsOneWidget);
    expect(find.text('Synthetic electricity bill'), findsOneWidget);
    expect(home.pollCalls, 0);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('file selection failure has a specific recoverable message', (
    t,
  ) async {
    final auth = authenticatedUser();
    await t.pumpWidget(
      FamilyDocumentsApp(
        auth: auth,
        homeService: FakeHomeService(auth),
        pickUpload: () async => throw StateError('synthetic picker failure'),
      ),
    );
    await t.pump();
    await t.tap(find.byTooltip('Attach a document').last);
    await t.pumpAndSettle();
    expect(
      find.text('I couldn’t read the selected file. Please choose it again.'),
      findsOneWidget,
    );
  });

  testWidgets('app-wide processing indicator opens Timeline', (t) async {
    final auth = authenticatedUser();
    final home = FakeHomeService(
      auth,
      pendingJobs: const [
        AnalysisJob(
          id: 'job-1',
          documentId: 'document-1',
          status: 'processing',
          displayTitle: 'Electricity bill',
        ),
      ],
      pollingResult: const AnalysisJob(
        id: 'job-1',
        documentId: 'document-1',
        status: 'processing',
        displayTitle: 'Electricity bill',
      ),
    );
    await t.pumpWidget(
      FamilyDocumentsApp(
        auth: auth,
        homeService: home,
        timelineService: FakeTimelineService(auth),
      ),
    );
    await t.pump(const Duration(milliseconds: 100));
    expect(find.text('1 document processing'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('processing-indicator')));
    await t.pump(const Duration(milliseconds: 100));
    await t.pump();
    expect(
      find.text('Everything you’ve saved and received, newest first.'),
      findsOneWidget,
    );
    expect(find.text('Reading Electricity bill…'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('OCR completion notification appears once and opens Timeline', (
    t,
  ) async {
    final auth = authenticatedUser();
    final home = FakeHomeService(
      auth,
      pendingJobs: const [
        AnalysisJob(
          id: 'job-1',
          documentId: 'document-1',
          status: 'processing',
        ),
      ],
      pollingResult: const AnalysisJob(
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
    );
    await t.pumpWidget(
      FamilyDocumentsApp(
        auth: auth,
        homeService: home,
        timelineService: FakeTimelineService(auth),
      ),
    );
    await t.pump(const Duration(milliseconds: 100));
    expect(find.text('Finished reading your document.'), findsOneWidget);
    expect(find.text('Finished reading your document.'), findsNWidgets(1));
    t.widget<SnackBarAction>(find.byType(SnackBarAction)).onPressed();
    await t.pump(const Duration(milliseconds: 100));
    expect(find.text('Timeline'), findsWidgets);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('refresh restores pending jobs in Timeline without duplicates', (
    t,
  ) async {
    final auth = authenticatedUser();
    final home = FakeHomeService(
      auth,
      pendingJobs: const [
        AnalysisJob(
          id: 'job-1',
          documentId: 'document-1',
          status: 'queued',
          displayTitle: 'Passport',
        ),
      ],
      pollingResult: const AnalysisJob(
        id: 'job-1',
        documentId: 'document-1',
        status: 'queued',
        displayTitle: 'Passport',
      ),
    );
    await t.pumpWidget(
      FamilyDocumentsApp(
        auth: auth,
        homeService: home,
        timelineService: FakeTimelineService(auth),
      ),
    );
    await t.pump(const Duration(milliseconds: 100));
    await t.tap(find.text('Timeline').first);
    await t.pump(const Duration(milliseconds: 100));
    await t.pump();
    expect(find.text('Passport queued for reading'), findsOneWidget);
    await t.tap(find.byTooltip('Refresh Timeline'));
    await t.pump(const Duration(milliseconds: 100));
    await t.pump();
    expect(find.text('Passport queued for reading'), findsOneWidget);
    expect(home.restoreCalls, 2);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('sign out stops background polling', (t) async {
    final auth = authenticatedUser();
    final home = FakeHomeService(
      auth,
      pendingJobs: const [
        AnalysisJob(
          id: 'job-1',
          documentId: 'document-1',
          status: 'processing',
        ),
      ],
    );
    await t.pumpWidget(
      FamilyDocumentsApp(
        auth: auth,
        homeService: home,
        timelineService: FakeTimelineService(auth),
      ),
    );
    await t.pump(const Duration(milliseconds: 100));
    final menu = t.widget<PopupMenuButton<String>>(
      find.byKey(const ValueKey('profile-avatar')),
    );
    menu.onSelected!('signout');
    await t.pump(const Duration(milliseconds: 100));
    final callsAfterSignOut = home.pollCalls;
    await t.pump(const Duration(seconds: 3));
    expect(home.pollCalls, callsAfterSignOut);
    expect(find.text('Sign in'), findsOneWidget);
  });
}
