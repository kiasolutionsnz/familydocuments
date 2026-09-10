import 'dart:async';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'core/auth/auth_service.dart';
import 'core/home/home_intent.dart';
import 'core/home/home_service.dart';
import 'core/home/reminder_parser.dart';
import 'core/navigation/destination_state.dart';
import 'features/conversation/conversation_controller.dart';
import 'features/conversation/data/conversation_service.dart';
import 'features/conversation/models/conversation_models.dart';
import 'features/conversation/widgets/conversation_transcript.dart';
import 'features/inbox/data/inbox_service.dart';
import 'features/inbox/inbox_page.dart';
import 'features/inbox/models/inbox_models.dart';
import 'features/library/data/library_service.dart';
import 'features/library/library_page.dart';
import 'features/library/library_navigation.dart';
import 'features/library/models/library_models.dart';
import 'features/timeline/data/timeline_service.dart';
import 'features/timeline/timeline_page.dart';

void main() => runApp(const FamilyDocumentsApp());

class SelectedUpload {
  const SelectedUpload({required this.name, required this.bytes});
  final String name;
  final Uint8List bytes;
}

class FamilyDocumentsApp extends StatefulWidget {
  const FamilyDocumentsApp({
    super.key,
    this.auth,
    this.homeService,
    this.timelineService,
    this.libraryService,
    this.inboxService,
    this.pickUpload,
    this.destinationState,
    this.conversationRepository,
  });
  final AuthService? auth;
  final HomeService? homeService;
  final TimelineService? timelineService;
  final LibraryService? libraryService;
  final InboxService? inboxService;
  final Future<SelectedUpload?> Function()? pickUpload;
  final DestinationState? destinationState;
  final ConversationRepository? conversationRepository;
  @override
  State<FamilyDocumentsApp> createState() => _AppState();
}

class _AppState extends State<FamilyDocumentsApp> {
  final navigatorKey = GlobalKey<NavigatorState>();
  late final AuthService auth;
  late final HomeService homeService;
  late final TimelineService timelineService;
  late final LibraryService libraryService;
  late final InboxService inboxService;
  late final LibraryNavigation libraryNavigation;
  late final DestinationState destinationState;
  late final ConversationController conversationController;
  StreamSubscription<PrimaryDestination>? destinationSubscription;
  late final bool ownsDestinationState;
  bool checking = true, signingIn = false, busy = false;
  String? error, message, retryAction;
  SearchResponse? searchResponse;
  OrganisedDocument? organisedDocument;
  String? suggestedDestination;
  String? unresolvedCategory;
  bool categoryMatchAmbiguous = false;
  String? uploadedName, uploadedMimeType;
  Uint8List? uploadedBytes;
  final Map<String, AnalysisJob> analysisJobs = {};
  final Map<String, String> analysisConversations = {};
  Timer? analysisTimer;
  String? analysisRequestId;
  String? reminderRequestId, reminderInstruction;
  String? pendingLinkUrl, pendingLinkTitle, unresolvedLinkCategory;
  List<SavedLinkCategory> pendingLinkCategories = const [];
  SavedLinkCategory? pendingLinkSaveCategory;
  final Set<String> notifiedAnalysisJobs = {};
  int tab = 0;
  final query = TextEditingController();
  @override
  void initState() {
    super.initState();
    auth = widget.auth ?? AuthService();
    homeService = widget.homeService ?? HomeService(auth);
    timelineService = widget.timelineService ?? TimelineService(auth);
    libraryService = widget.libraryService ?? LibraryService(auth);
    inboxService = widget.inboxService ?? InboxService(auth);
    libraryNavigation = createLibraryNavigation();
    final injectedHarness =
        widget.auth != null ||
        widget.homeService != null ||
        widget.timelineService != null ||
        widget.libraryService != null ||
        widget.inboxService != null;
    conversationController = ConversationController(
      repository:
          widget.conversationRepository ??
          (injectedHarness
              ? MemoryConversationRepository()
              : ConversationService(auth)),
      execute: _executeConversationAction,
    )..addListener(_conversationChanged);
    ownsDestinationState = widget.destinationState == null;
    destinationState = widget.destinationState ?? createDestinationState();
    destinationSubscription = destinationState.changes.listen((destination) {
      if (!mounted || auth.session == null) return;
      final next = destination.index;
      if (tab != next) setState(() => tab = next);
    });
    _restore();
  }

  Future<void> _restore() async {
    try {
      await auth.restore();
    } catch (_) {}
    if (auth.session != null) {
      tab = destinationState.current.index;
      try {
        await conversationController.restore();
        _bindConversationJobs();
      } catch (_) {}
      await _restoreAnalysisJobs();
    } else {
      destinationState.reset();
      tab = PrimaryDestination.home.index;
    }
    if (mounted) setState(() => checking = false);
  }

  Future<void> signIn(String e, String p) async {
    setState(() => signingIn = true);
    try {
      await auth.signIn(e, p);
      destinationState.reset();
      tab = PrimaryDestination.home.index;
      try {
        await conversationController.restore();
        _bindConversationJobs();
      } catch (_) {}
      await _restoreAnalysisJobs();
      if (mounted) setState(() => error = null);
    } on AuthException catch (x) {
      if (mounted) setState(() => error = x.message);
    } finally {
      if (mounted) setState(() => signingIn = false);
    }
  }

  Future<void> send() async {
    final instruction = query.text.trim();
    if (busy || conversationController.loading) return;
    final hasAttachment = uploadedBytes != null;
    await conversationController.submit(
      instruction,
      hasAttachment: hasAttachment,
      attachmentId: hasAttachment
          ? 'attachment-${sha256.convert(uploadedBytes!).toString().substring(0, 24)}'
          : null,
      attachmentLabel: uploadedName,
    );
    if (mounted) query.clear();
  }

  void _conversationChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _newConversation() async {
    clearAttachment();
    setState(() {
      message = null;
      error = null;
      searchResponse = null;
      organisedDocument = null;
      suggestedDestination = null;
      retryAction = null;
    });
    await conversationController.newConversation();
  }

  Future<ConversationExecutionResult> _executeConversationAction(
    ConversationAction action,
  ) async {
    switch (action.type) {
      case ConversationActionType.searchFamilyContent:
        final result = await homeService.search(
          action.parameters['query'].toString(),
        );
        final references = result.documents
            .where((document) => _isUuid(document.id))
            .map(
              (document) => ConversationReference(
                type: 'document',
                id: document.id!,
                label: document.title,
                metadata: {
                  if (document.collection != null)
                    'category': document.collection,
                  if (document.date != null) 'important_date': document.date,
                  if (document.matchType != null)
                    'match_type': document.matchType,
                },
              ),
            )
            .toList();
        return ConversationExecutionResult(
          message: result.documents.isEmpty
              ? 'I couldn’t find that in your FamilyDocuments account.'
              : result.answer,
          data: {
            'results': result.documents
                .map(
                  (document) => {
                    'title': document.title,
                    if (document.collection != null)
                      'category': document.collection,
                    if (document.date != null) 'date': document.date,
                    'match_type': document.matchType ?? 'metadata',
                  },
                )
                .toList(),
          },
          references: references,
          suggestions: result.documents.isEmpty
              ? const []
              : [
                  if (references.isNotEmpty)
                    _suggestion(
                      'Open ${references.first.label}',
                      ConversationActionType.openAppDestination,
                      {'destination': 'library', 'result_index': 0},
                    ),
                  _suggestion(
                    'Refine search',
                    ConversationActionType.requestClarification,
                    {
                      'question': 'What should I narrow the search to?',
                      'missing_parameter': 'search_query',
                    },
                  ),
                  _suggestion(
                    'View in Library',
                    ConversationActionType.openAppDestination,
                    {'destination': 'library'},
                  ),
                ],
        );
      case ConversationActionType.saveDocument:
        final bytes = uploadedBytes;
        final name = uploadedName;
        final mimeType = uploadedMimeType;
        if (bytes == null || name == null || mimeType == null) {
          throw HomeServiceException('Attach the document you want to save.');
        }
        final requested = action.parameters['category_name']?.toString() ?? '';
        var resolution = await homeService.resolveCategory(requested);
        if (resolution.type == CategoryResolutionType.missing &&
            action.parameters['create_category'] == true) {
          final created = await homeService.createCategory(requested);
          resolution = CategoryResolution.found(created);
        }
        if (resolution.type != CategoryResolutionType.found) {
          final choices = resolution.type == CategoryResolutionType.ambiguous
              ? resolution.matches
              : await homeService.categories();
          final suggestions = <ConversationSuggestion>[
            if (resolution.type == CategoryResolutionType.missing)
              _suggestion(
                'Create and save',
                ConversationActionType.saveDocument,
                {
                  ...action.parameters,
                  'category_name': canonicalCategoryName(requested),
                  'create_category': true,
                },
              ),
            ...choices
                .take(2)
                .map(
                  (category) => _suggestion(
                    category,
                    ConversationActionType.saveDocument,
                    {...action.parameters, 'category_name': category},
                  ),
                ),
          ];
          return ConversationExecutionResult(
            message: resolution.type == CategoryResolutionType.ambiguous
                ? 'I found more than one matching category. Which one should I use?'
                : 'Your Family doesn’t have a ${canonicalCategoryName(requested)} category yet.',
            suggestions: suggestions.take(3).toList(),
          );
        }
        final saved = await homeService.saveUpload(
          name: name,
          mimeType: mimeType,
          bytes: bytes,
          category: resolution.category!,
        );
        clearAttachment();
        return ConversationExecutionResult(
          message: 'Saved ${saved.title} in ${saved.category}.',
          data: {'category': saved.category, 'tags': saved.tags},
          references: _documentReference(saved),
          suggestions: [
            _suggestion(
              'Add tags',
              ConversationActionType.requestClarification,
              {
                'question': 'Which tags should I add?',
                'missing_parameter': 'tags',
              },
            ),
            _suggestion(
              'View in ${saved.category}',
              ConversationActionType.openAppDestination,
              {'destination': 'library'},
            ),
          ],
        );
      case ConversationActionType.requestDocumentOcr:
        var bytes = uploadedBytes;
        var name = uploadedName;
        var mimeType = uploadedMimeType;
        final existingDocumentId = action.parameters['document_id']?.toString();
        if ((bytes == null || name == null || mimeType == null) &&
            existingDocumentId != null) {
          final source = await libraryService.source(existingDocumentId);
          bytes = source.bytes;
          name = source.fileName;
          mimeType = source.mimeType;
        }
        if (bytes == null || name == null || mimeType == null) {
          throw HomeServiceException(
            'Attach the document you want me to read.',
          );
        }
        final mode = action.parameters['mode']?.toString() == 'invoice'
            ? 'invoice'
            : 'document';
        final job = (await homeService.submitAnalysisJob(
          name: name,
          mimeType: mimeType,
          bytes: bytes,
          invoice: mode == 'invoice',
          idempotencyKey: 'ocr-$mode-${sha256.convert(bytes)}',
        )).withDisplayTitle(name.replaceFirst(RegExp(r'\.[^.]+$'), ''));
        if (mounted) {
          setState(() {
            analysisJobs[job.id] = job;
            final conversationId = conversationController.conversationId;
            if (conversationId != null) {
              analysisConversations[job.id] = conversationId;
            }
            if (uploadedBytes != null) {
              uploadedBytes = null;
              uploadedName = null;
              uploadedMimeType = null;
            }
          });
        }
        if (!job.terminal) _startAnalysisPolling();
        return ConversationExecutionResult(
          message: job.status == 'succeeded'
              ? 'Finished reading ${job.displayTitle ?? 'your document'}.'
              : 'Uploaded ${job.displayTitle ?? 'your document'}. It is queued for reading.',
          data: {
            'correlation_id': 'ocr:${job.id}',
            'status': job.status,
            'job_id': job.id,
            if (job.result != null) 'category': job.result!.category,
            if (job.result != null) 'tags': job.result!.tags,
          },
          references: _isUuid(job.documentId)
              ? [
                  ConversationReference(
                    type: 'document',
                    id: job.documentId,
                    label: job.displayTitle ?? 'Document',
                  ),
                ]
              : const [],
          suggestions: _isUuid(job.documentId)
              ? [
                  _suggestion(
                    'Review category',
                    ConversationActionType.requestClarification,
                    {
                      'question': 'Which category should this document use?',
                      'missing_parameter': 'change_category',
                    },
                  ),
                  _suggestion(
                    'Add tags',
                    ConversationActionType.requestClarification,
                    {
                      'question': 'Which tags should I add?',
                      'missing_parameter': 'tags',
                    },
                  ),
                  _suggestion(
                    'Open document',
                    ConversationActionType.openAppDestination,
                    {'destination': 'library', 'result_index': 0},
                  ),
                ]
              : const [],
        );
      case ConversationActionType.createReminder:
        final result = await homeService.createReminder(
          title: action.parameters['title'].toString(),
          dueDate: action.parameters['due_date'].toString(),
          dueTime: action.parameters['due_time']?.toString(),
          requestId: action.parameters['request_id'].toString(),
          documentId: action.parameters['document_id']?.toString(),
        );
        return ConversationExecutionResult(
          message:
              'Reminder added: ${result.title} — ${result.dueDate}${result.dueTime == null ? '' : ' at ${result.dueTime}'}.',
          references: _isUuid(result.id)
              ? [
                  ConversationReference(
                    type: 'reminder',
                    id: result.id,
                    label: result.title,
                    metadata: {
                      'due_date': result.dueDate,
                      if (result.dueTime != null) 'due_time': result.dueTime,
                    },
                  ),
                ]
              : const [],
          suggestions: [
            _suggestion(
              'View Reminders',
              ConversationActionType.openAppDestination,
              {'destination': 'reminders'},
            ),
          ],
        );
      case ConversationActionType.saveLink:
        final requested = action.parameters['category_name']?.toString().trim();
        if (requested == null || requested.isEmpty) {
          throw HomeServiceException('Tell me which link category to use.');
        }
        var categories = await homeService.linkCategories();
        final key = requested.toLowerCase();
        var matches = categories
            .where(
              (category) =>
                  category.name.toLowerCase() == key ||
                  category.name.toLowerCase().startsWith('$key '),
            )
            .toList();
        if (matches.isEmpty && action.parameters['create_category'] == true) {
          final created = await homeService.createLinkCategory(requested);
          categories = [...categories, created];
          matches = [created];
        }
        if (matches.length != 1) {
          return ConversationExecutionResult(
            message: matches.isEmpty
                ? 'Your Family doesn’t have a $requested link category yet.'
                : 'I found more than one matching link category. Which one should I use?',
            suggestions: [
              if (matches.isEmpty)
                _suggestion(
                  'Create and save',
                  ConversationActionType.saveLink,
                  {...action.parameters, 'create_category': true},
                ),
              ...categories
                  .take(2)
                  .map(
                    (category) => _suggestion(
                      category.name,
                      ConversationActionType.saveLink,
                      {...action.parameters, 'category_name': category.name},
                    ),
                  ),
            ].take(3).toList(),
          );
        }
        final saved = await homeService.saveLink(
          url: action.parameters['url'].toString(),
          title: action.parameters['title'].toString(),
          category: matches.single,
        );
        return ConversationExecutionResult(
          message: saved.duplicate
              ? 'This link is already saved in ${saved.category}.'
              : 'Saved ${saved.title} in ${saved.category}.',
          data: {'category': saved.category, 'url': action.parameters['url']},
          references: _isUuid(saved.id)
              ? [
                  ConversationReference(
                    type: 'link',
                    id: saved.id,
                    label: saved.title,
                  ),
                ]
              : const [],
          suggestions: [
            _suggestion(
              'View Saved Links',
              ConversationActionType.openAppDestination,
              {'destination': 'library'},
            ),
          ],
        );
      case ConversationActionType.updateDocumentCategory:
      case ConversationActionType.updateDocumentTags:
        final documentId = action.parameters['document_id'].toString();
        final data = await libraryService.load(limit: 100);
        final matching = data.documents
            .where((document) => document.id == documentId)
            .toList();
        if (matching.length != 1 || !matching.single.canEdit) {
          throw const LibraryServiceException(
            'You no longer have access to this item.',
            accessRevoked: true,
          );
        }
        final document = matching.single;
        var categoryId = document.categoryId;
        var tags = List<String>.from(document.tags);
        if (action.type == ConversationActionType.updateDocumentCategory) {
          final requested = action.parameters['category_name']
              .toString()
              .toLowerCase();
          final categories = data.categories
              .where((category) => category.name.toLowerCase() == requested)
              .toList();
          if (categories.length != 1) {
            throw const LibraryServiceException(
              'Choose one existing Family category.',
            );
          }
          categoryId = categories.single.id;
        } else {
          final requestedTags = (action.parameters['tags'] as List)
              .map((tag) => ConversationController.normaliseTag(tag.toString()))
              .where((tag) => tag.isNotEmpty)
              .toSet();
          if (action.parameters['operation'] == 'remove') {
            tags.removeWhere(
              (tag) => requestedTags.contains(
                ConversationController.normaliseTag(tag),
              ),
            );
          } else {
            tags = {
              ...tags.map(ConversationController.normaliseTag),
              ...requestedTags,
            }.toList();
          }
        }
        await libraryService.updateDocument(
          document: document,
          categoryId: categoryId,
          tags: tags,
        );
        final category = data.categories
            .where((item) => item.id == categoryId)
            .firstOrNull;
        return ConversationExecutionResult(
          message: action.type == ConversationActionType.updateDocumentCategory
              ? 'Changed ${document.title} to ${category?.name ?? document.category}.'
              : 'Updated the tags on ${document.title}.',
          data: {'category': category?.name ?? document.category, 'tags': tags},
          references: [
            ConversationReference(
              type: 'document',
              id: document.id,
              label: document.title,
              metadata: {'category': category?.name ?? document.category},
            ),
          ],
        );
      case ConversationActionType.markInboxReviewed:
      case ConversationActionType.dismissInboxItem:
        final item = await inboxService.detail(
          action.parameters['inbox_id'].toString(),
        );
        await inboxService.setReviewState(
          item,
          action.type == ConversationActionType.dismissInboxItem
              ? 'dismissed'
              : 'reviewed',
        );
        return ConversationExecutionResult(
          message: action.type == ConversationActionType.dismissInboxItem
              ? 'Dismissed ${item.subject} from Inbox.'
              : 'Marked ${item.subject} as reviewed.',
        );
      case ConversationActionType.openAppDestination:
        final destination = action.parameters['destination'].toString();
        final index = const {
          'home': 0,
          'timeline': 1,
          'library': 2,
          'inbox': 3,
          'reminders': 4,
        }[destination]!;
        final resultIndex = action.parameters['result_index'] as int?;
        if (destination == 'library' &&
            resultIndex != null &&
            resultIndex < conversationController.references.length) {
          final reference = conversationController.references[resultIndex];
          if (reference.type == 'document') {
            libraryNavigation.open(
              LibraryLocation(LibrarySection.documents, itemId: reference.id),
            );
          }
        }
        _selectTab(index);
        return ConversationExecutionResult(
          message: 'Opened ${Shell.labels[index]}.',
        );
      case ConversationActionType.updateReminder:
        final result = await homeService.moveReminderOneWeekBefore(
          reminderId: action.parameters['reminder_id'].toString(),
          expectedDueDate: action.parameters['expected_due_date'].toString(),
        );
        return ConversationExecutionResult(
          message:
              'Updated ${result.title}. I’ll remind you on ${result.dueDate}${result.dueTime == null ? '' : ' at ${result.dueTime}'}.',
          references: [
            ConversationReference(
              type: 'reminder',
              id: result.id,
              label: result.title,
              metadata: {
                'due_date': result.dueDate,
                if (result.dueTime != null) 'due_time': result.dueTime,
              },
            ),
          ],
        );
      case ConversationActionType.requestClarification:
      case ConversationActionType.requestConfirmation:
      case ConversationActionType.unsupportedRequest:
        throw StateError('Non-executable conversation action.');
    }
  }

  List<ConversationReference> _documentReference(OrganisedDocument document) =>
      _isUuid(document.id)
      ? [
          ConversationReference(
            type: 'document',
            id: document.id!,
            label: document.title,
            metadata: {'category': document.category, 'tags': document.tags},
          ),
        ]
      : const [];

  ConversationSuggestion _suggestion(
    String label,
    ConversationActionType type,
    Map<String, dynamic> parameters,
  ) => ConversationSuggestion(
    label: label,
    action: ConversationAction(
      id: 'suggestion-${DateTime.now().microsecondsSinceEpoch}',
      type: type,
      parameters: parameters,
    ),
  );

  static bool _isUuid(String? value) =>
      value != null &&
      RegExp(
        r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
        caseSensitive: false,
      ).hasMatch(value);

  Future<void> _startLinkConversation(HomeIntent intent) async {
    setState(() {
      busy = true;
      error = null;
      message = 'Finding your link categories…';
      pendingLinkUrl = intent.linkUrl;
      pendingLinkTitle = intent.linkTitle;
      unresolvedLinkCategory = null;
      retryAction = 'link-start';
    });
    try {
      final categories = await homeService.linkCategories();
      if (!mounted) return;
      setState(() {
        pendingLinkCategories = categories;
        message = categories.isEmpty
            ? 'What category should I create for this link?'
            : 'Which category should I save this link in?';
        query.clear();
        retryAction = null;
      });
    } on HomeServiceException catch (failure) {
      if (mounted) setState(() => error = failure.message);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> chooseLinkCategory(SavedLinkCategory category) =>
      _savePendingLink(category);

  Future<void> createAndSaveLinkCategory() async {
    final name = unresolvedLinkCategory;
    if (name == null || busy) return;
    setState(() {
      busy = true;
      error = null;
      message = 'Creating $name…';
    });
    try {
      final category = await homeService.createLinkCategory(name);
      await _savePendingLink(category, managesBusyState: false);
    } on HomeServiceException catch (failure) {
      if (mounted) setState(() => error = failure.message);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _savePendingLink(
    SavedLinkCategory category, {
    bool managesBusyState = true,
  }) async {
    final url = pendingLinkUrl;
    final title = pendingLinkTitle;
    if (url == null || title == null || busy && managesBusyState) return;
    if (managesBusyState) setState(() => busy = true);
    setState(() {
      error = null;
      message = 'Saving your link…';
      pendingLinkSaveCategory = category;
      retryAction = 'link-save';
    });
    try {
      final result = await homeService.saveLink(
        url: url,
        title: title,
        category: category,
      );
      if (!mounted) return;
      _clearLinkConversation(
        messageText: result.duplicate
            ? 'This link is already saved in ${result.category}.'
            : 'Saved ${result.title} in ${result.category}.',
      );
    } on HomeServiceException catch (failure) {
      if (mounted) setState(() => error = failure.message);
    } finally {
      if (mounted && managesBusyState) setState(() => busy = false);
    }
  }

  void cancelLinkConversation() =>
      _clearLinkConversation(messageText: 'Okay, I didn’t save the link.');

  void _clearLinkConversation({required String messageText}) => setState(() {
    pendingLinkUrl = null;
    pendingLinkTitle = null;
    pendingLinkCategories = const [];
    pendingLinkSaveCategory = null;
    unresolvedLinkCategory = null;
    retryAction = null;
    query.clear();
    message = messageText;
    error = null;
  });

  Future<void> _createReminder(String instruction) async {
    ParsedReminder parsed;
    try {
      parsed = parseReminderCommand(instruction);
    } on ReminderClarification catch (clarification) {
      setState(() {
        message = clarification.message;
        error = null;
      });
      return;
    }
    setState(() {
      busy = true;
      error = null;
      message = 'Adding your reminder…';
      retryAction = 'reminder';
    });
    if (reminderInstruction != instruction) {
      reminderInstruction = instruction;
      reminderRequestId =
          'home-${auth.session?.userId ?? 'user'}-${DateTime.now().microsecondsSinceEpoch}';
    }
    try {
      final result = await homeService.createReminder(
        title: parsed.title,
        dueDate: parsed.dueDate,
        dueTime: parsed.dueTime,
        requestId: reminderRequestId!,
      );
      if (mounted) {
        setState(() {
          message = 'Reminder added: ${result.title} — ${parsed.displayWhen}';
          retryAction = null;
          reminderRequestId = null;
          reminderInstruction = null;
          query.clear();
        });
      }
    } on HomeServiceException catch (failure) {
      if (mounted) setState(() => error = failure.message);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> search() async {
    if (query.text.trim().isEmpty) return;
    final submitted = query.text.trim();
    setState(() {
      busy = true;
      error = null;
      retryAction = 'search';
      message = null;
      searchResponse = null;
      organisedDocument = null;
    });
    try {
      final result = await homeService.search(submitted);
      if (mounted) {
        setState(() => searchResponse = result);
      }
    } on AuthException catch (x) {
      await auth.clear();
      if (mounted) {
        setState(() => error = x.message);
      }
    } on HomeServiceException catch (x) {
      if (mounted) {
        setState(() => error = x.message);
      }
    } catch (_) {
      if (mounted) {
        setState(() => error = 'Search could not be reached. Try again.');
      }
    } finally {
      if (mounted) {
        setState(() => busy = false);
      }
    }
  }

  Future<void> upload() async {
    SelectedUpload? selected;
    try {
      selected = widget.pickUpload != null
          ? await widget.pickUpload!()
          : await _pickFile();
    } catch (_) {
      if (mounted) {
        setState(
          () => error =
              'I couldn’t read the selected file. Please choose it again.',
        );
      }
      return;
    }
    if (selected == null) return;
    final upload = selected;
    setState(() {
      error = null;
      uploadedName = upload.name;
      uploadedMimeType = _mimeType(upload.name);
      uploadedBytes = upload.bytes;
      message = null;
      analysisRequestId = null;
    });
  }

  Future<SelectedUpload?> _pickFile() async {
    final result = await FilePicker.platform.pickFiles(
      withData: true,
      type: FileType.custom,
      allowedExtensions: ['pdf', 'jpg', 'jpeg', 'png'],
    );
    if (result == null) return null;
    if (result.files.single.bytes == null ||
        result.files.single.bytes!.isEmpty) {
      throw StateError('selected file has no readable bytes');
    }
    final file = result.files.single;
    return SelectedUpload(name: file.name, bytes: file.bytes!);
  }

  Future<void> _sendAttachment() async {
    final instruction = query.text.trim();
    final intent = parseHomeIntent(instruction, hasAttachment: true);
    final name = uploadedName!;
    if (intent.type == HomeIntentType.vagueAttachment) {
      final hint = metadataCategoryHint(name);
      if (hint != null) {
        setState(() {
          message = 'This looks like it belongs in $hint. Save it there?';
          suggestedDestination = hint;
          error = null;
        });
        return;
      }
    }
    final needsAnalysis =
        intent.type == HomeIntentType.readAttachment ||
        intent.type == HomeIntentType.invoiceAttachment ||
        intent.type == HomeIntentType.vagueAttachment;
    final category = intent.destination;
    if (!needsAnalysis && category == null) {
      setState(
        () => error = 'Tell me where to save it, for example “Add to Rental 1”, or ask me to read it as a bill.',
      );
      return;
    }
    final bytes = uploadedBytes!;
    final mimeType = uploadedMimeType!;
    setState(() {
      busy = true;
      error = null;
      retryAction = 'upload';
      message = needsAnalysis
          ? 'Reading your document…'
          : 'Saving to $category…';
      searchResponse = null;
      organisedDocument = null;
      suggestedDestination = null;
      unresolvedCategory = null;
      categoryMatchAmbiguous = false;
    });
    try {
      if (needsAnalysis) {
        final analysisMode = intent.type == HomeIntentType.invoiceAttachment
            ? 'invoice'
            : 'document';
        analysisRequestId ??=
            'ocr-$analysisMode-${sha256.convert(bytes).toString()}';
        final submittedJob = await homeService.submitAnalysisJob(
          name: name,
          mimeType: mimeType,
          bytes: bytes,
          invoice: intent.type == HomeIntentType.invoiceAttachment,
          idempotencyKey: analysisRequestId!,
        );
        final job = submittedJob.withDisplayTitle(
          name.replaceFirst(RegExp(r'\.[^.]+$'), ''),
        );
        if (mounted) {
          setState(() {
            analysisJobs[job.id] = job;
            if (job.status == 'succeeded' && job.result != null) {
              organisedDocument = job.result;
              notifiedAnalysisJobs.add(job.id);
              message = null;
            } else if (job.status == 'failed' ||
                job.status == 'permanent_failed') {
              error = 'The file was saved, but I couldn’t read its contents.';
              retryAction = job.retryAllowed ? 'analysis:${job.id}' : null;
              message = null;
            } else {
              message = 'Uploaded. Reading $name in the background…';
            }
            uploadedBytes = null;
            uploadedName = null;
            uploadedMimeType = null;
            analysisRequestId = null;
            query.clear();
          });
          if (!job.terminal) _startAnalysisPolling();
        }
        return;
      }
      final resolution = await homeService.resolveCategory(category!);
      if (!mounted) return;
      if (resolution.type != CategoryResolutionType.found) {
        final canonical = canonicalCategoryName(category);
        setState(() {
          unresolvedCategory = category;
          categoryMatchAmbiguous =
              resolution.type == CategoryResolutionType.ambiguous;
          retryAction = null;
          message = categoryMatchAmbiguous
              ? 'I found more than one matching category. Which one should I use?'
              : 'Your family doesn’t have a $canonical category yet. Would you like to create it?';
        });
        return;
      }
      final result = await homeService.saveUpload(
        name: name,
        mimeType: mimeType,
        bytes: bytes,
        category: resolution.category!,
      );
      if (mounted) {
        setState(() {
          message = 'Saved in ${result.category}.';
          organisedDocument = result;
          uploadedBytes = null;
          uploadedName = null;
          uploadedMimeType = null;
          retryAction = null;
          query.clear();
        });
      }
    } on AuthException catch (x) {
      await auth.clear();
      if (mounted) {
        setState(() => error = x.message);
      }
    } on HomeServiceException catch (x) {
      if (mounted) {
        setState(() => error = x.message);
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => error = needsAnalysis
              ? 'The file couldn’t be uploaded. Try again.'
              : 'Something went wrong while saving the document.',
        );
      }
    } finally {
      if (mounted) {
        setState(() => busy = false);
      }
    }
  }

  Future<void> _restoreAnalysisJobs() async {
    try {
      final jobs = await homeService.pendingAnalysisJobs();
      if (!mounted || jobs.isEmpty) return;
      setState(() {
        analysisJobs.clear();
        for (final job in jobs) {
          analysisJobs[job.id] = job;
          if (job.terminal) notifiedAnalysisJobs.add(job.id);
        }
        final completed = jobs
            .where((job) => job.status == 'succeeded' && job.result != null)
            .lastOrNull;
        final failed = jobs
            .where(
              (job) =>
                  job.status == 'failed' || job.status == 'permanent_failed',
            )
            .lastOrNull;
        if (completed != null) {
          organisedDocument = completed.result;
          message = null;
        } else if (failed != null) {
          error = 'The file was saved, but I couldn’t read its contents.';
          retryAction = failed.retryAllowed ? 'analysis:${failed.id}' : null;
        } else {
          message = 'Resuming document processing…';
        }
      });
      _startAnalysisPolling();
    } catch (_) {}
  }

  void _startAnalysisPolling() {
    if (analysisTimer?.isActive ?? false) return;
    analysisTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => _pollAnalysisJobs(),
    );
    _pollAnalysisJobs();
  }

  Future<void> _pollAnalysisJobs() async {
    if (!mounted || auth.session == null) {
      _stopAnalysisPolling();
      return;
    }
    final active = analysisJobs.values.where((job) => !job.terminal).toList();
    if (active.isEmpty) {
      _stopAnalysisPolling();
      return;
    }
    for (final current in active) {
      try {
        final job = await homeService.analysisJob(current.id);
        if (!mounted) return;
        final completedNow =
            !current.terminal &&
            job.status == 'succeeded' &&
            job.result != null &&
            notifiedAnalysisJobs.add(job.id);
        setState(() {
          analysisJobs[job.id] = job;
          if (job.status == 'succeeded' && job.result != null) {
            organisedDocument = job.result;
            message = null;
          } else if (job.status == 'failed' ||
              job.status == 'permanent_failed') {
            error = 'The file was saved, but I couldn’t read its contents.';
            retryAction = job.retryAllowed ? 'analysis:${job.id}' : null;
          } else {
            message = job.status == 'queued'
                ? 'Your document is queued for reading…'
                : 'Reading your document in the background…';
          }
        });
        final activeConversation = conversationController.conversationId;
        final belongsToActiveConversation =
            analysisConversations[job.id] == activeConversation ||
            conversationController.hasCorrelation('ocr:${job.id}');
        if (belongsToActiveConversation) {
          await conversationController.updateProgress(
            correlationId: 'ocr:${job.id}',
            text: job.status == 'succeeded' && job.result != null
                ? 'Finished reading ${job.result!.title}.'
                : job.status == 'failed' || job.status == 'permanent_failed'
                ? 'I couldn’t read ${job.displayTitle ?? 'that document'}.'
                : job.status == 'queued'
                ? '${job.displayTitle ?? 'Your document'} is queued for reading.'
                : 'Reading ${job.displayTitle ?? 'your document'}…',
            status: job.status == 'succeeded'
                ? 'finished'
                : job.status == 'failed' || job.status == 'permanent_failed'
                ? 'failed'
                : job.status,
            data: {
              'job_id': job.id,
              'document_id': job.documentId,
              if (job.result != null) 'category': job.result!.category,
              if (job.result != null) 'tags': job.result!.tags,
            },
            suggestions: job.status == 'succeeded' && _isUuid(job.documentId)
                ? [
                    _suggestion(
                      'Review category',
                      ConversationActionType.requestClarification,
                      {
                        'question': 'Which category should this document use?',
                        'missing_parameter': 'change_category',
                      },
                    ),
                    _suggestion(
                      'Add tags',
                      ConversationActionType.requestClarification,
                      {
                        'question': 'Which tags should I add?',
                        'missing_parameter': 'tags',
                      },
                    ),
                    _suggestion(
                      'Open document',
                      ConversationActionType.openAppDestination,
                      {'destination': 'library', 'result_index': 0},
                    ),
                  ]
                : const [],
          );
        }
        if (completedNow && tab != 1) _showAnalysisCompletion();
      } on AuthException {
        await auth.clear();
        _stopAnalysisPolling();
      } catch (_) {
        // A transient status failure does not cancel durable server processing.
      }
    }
  }

  void _stopAnalysisPolling() {
    analysisTimer?.cancel();
    analysisTimer = null;
  }

  void _bindConversationJobs() {
    final conversationId = conversationController.conversationId;
    if (conversationId == null) return;
    for (final message in conversationController.messages) {
      final jobId = message.data['job_id']?.toString();
      if (jobId != null && message.data['correlation_id'] == 'ocr:$jobId') {
        analysisConversations[jobId] = conversationId;
      }
    }
  }

  void _showAnalysisCompletion() {
    final context = navigatorKey.currentContext;
    if (context == null) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text('Finished reading your document.'),
        action: SnackBarAction(
          label: 'View',
          onPressed: () => setState(() => tab = 1),
        ),
      ),
    );
  }

  Future<void> refreshAnalysisJobs() => _restoreAnalysisJobs();

  Future<void> retryAnalysisJob(String id) async {
    final job = await homeService.retryAnalysisJob(id);
    if (!mounted) return;
    setState(() {
      analysisJobs[id] = job;
      error = null;
      notifiedAnalysisJobs.remove(id);
    });
    _startAnalysisPolling();
  }

  Future<void> saveAnalysisWithoutReading(String id) async {
    await homeService.dismissAnalysisJob(id);
    if (mounted) setState(() => analysisJobs.remove(id));
  }

  Future<void> chooseAnalysisCategory(String id) async {
    final categories = await homeService.categories();
    if (!mounted) return;
    final chosen = await showDialog<String>(
      context: navigatorKey.currentContext!,
      builder: (dialogContext) => SimpleDialog(
        title: const Text('Choose category'),
        children: categories
            .map(
              (category) => SimpleDialogOption(
                onPressed: () => Navigator.pop(dialogContext, category),
                child: Text(category),
              ),
            )
            .toList(),
      ),
    );
    if (chosen == null) return;
    await homeService.categorizeAnalysisJob(id, chosen);
    if (mounted) setState(() => analysisJobs.remove(id));
  }

  Future<void> retry() async {
    if (retryAction == 'link-start' && pendingLinkUrl != null) {
      return _startLinkConversation(
        HomeIntent(
          HomeIntentType.saveLink,
          linkUrl: pendingLinkUrl,
          linkTitle: pendingLinkTitle,
        ),
      );
    }
    if (retryAction == 'link-save' && pendingLinkSaveCategory != null) {
      return _savePendingLink(pendingLinkSaveCategory!);
    }
    if (retryAction == 'search') return search();
    if (retryAction == 'upload') return _sendAttachment();
    if (retryAction == 'reminder' && reminderInstruction != null) {
      return _createReminder(reminderInstruction!);
    }
    if (retryAction?.startsWith('analysis:') ?? false) {
      final id = retryAction!.substring('analysis:'.length);
      final job = await homeService.retryAnalysisJob(id);
      if (mounted) {
        setState(() {
          analysisJobs[id] = job;
          error = null;
          message = 'Trying to read your document again…';
          retryAction = null;
        });
      }
      _startAnalysisPolling();
    }
  }

  void clearAttachment() => setState(() {
    uploadedBytes = null;
    uploadedName = null;
    uploadedMimeType = null;
    analysisRequestId = null;
    unresolvedCategory = null;
    categoryMatchAmbiguous = false;
    pendingLinkUrl = null;
    pendingLinkTitle = null;
    pendingLinkCategories = const [];
    pendingLinkSaveCategory = null;
    unresolvedLinkCategory = null;
  });

  Future<void> saveSuggestion() async {
    if (suggestedDestination == null) return;
    query.text = 'Save this in $suggestedDestination';
    await _sendAttachment();
  }

  Future<void> createAndSaveCategory() async {
    final requested = unresolvedCategory;
    if (requested == null || uploadedBytes == null || busy) return;
    setState(() {
      busy = true;
      error = null;
      message = 'Creating your category…';
    });
    try {
      final category = await homeService.createCategory(requested);
      await _saveCurrentAttachmentIn(category);
    } on AuthException catch (failure) {
      await auth.clear();
      if (mounted) setState(() => error = failure.message);
    } on HomeServiceException catch (failure) {
      if (mounted) setState(() => error = failure.message);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> chooseUploadCategory() async {
    if (uploadedBytes == null || busy) return;
    try {
      final categories = await homeService.categories();
      if (!mounted) return;
      final chosen = await showDialog<String>(
        context: navigatorKey.currentContext!,
        builder: (dialogContext) => SimpleDialog(
          title: const Text('Choose category'),
          children: categories
              .map(
                (category) => SimpleDialogOption(
                  onPressed: () => Navigator.pop(dialogContext, category),
                  child: Text(category),
                ),
              )
              .toList(),
        ),
      );
      if (chosen == null) return;
      if (mounted) setState(() => busy = true);
      await _saveCurrentAttachmentIn(chosen);
    } on AuthException catch (failure) {
      await auth.clear();
      if (mounted) setState(() => error = failure.message);
    } on HomeServiceException catch (failure) {
      if (mounted) setState(() => error = failure.message);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _saveCurrentAttachmentIn(String category) async {
    final bytes = uploadedBytes;
    final name = uploadedName;
    final mimeType = uploadedMimeType;
    if (bytes == null || name == null || mimeType == null) return;
    if (mounted) {
      setState(() {
        error = null;
        message = 'Saving to $category…';
      });
    }
    final result = await homeService.saveUpload(
      name: name,
      mimeType: mimeType,
      bytes: bytes,
      category: category,
    );
    if (!mounted) return;
    setState(() {
      message = 'Saved in ${result.category}.';
      organisedDocument = result;
      uploadedBytes = null;
      uploadedName = null;
      uploadedMimeType = null;
      unresolvedCategory = null;
      categoryMatchAmbiguous = false;
      retryAction = null;
      query.clear();
    });
  }

  void cancelCategoryChoice() => setState(() {
    unresolvedCategory = null;
    categoryMatchAmbiguous = false;
    error = null;
    message = 'Not saved. Your document is still attached.';
  });

  Future<void> saveFailedAnalysisWithoutReading() async {
    final retry = retryAction;
    if (retry == null || !retry.startsWith('analysis:')) return;
    try {
      await homeService.dismissAnalysisJob(retry.substring('analysis:'.length));
      if (mounted) {
        setState(() {
          analysisJobs.remove(retry.substring('analysis:'.length));
          error = null;
          retryAction = null;
          message = 'Saved without reading. You can change its category later.';
        });
      }
    } on HomeServiceException catch (failure) {
      if (mounted) setState(() => error = failure.message);
    }
  }

  Future<void> chooseFailedAnalysisCategory() async {
    final retry = retryAction;
    if (retry == null || !retry.startsWith('analysis:')) return;
    try {
      final categories = await homeService.categories();
      if (!mounted) return;
      final chosen = await showDialog<String>(
        context: navigatorKey.currentContext!,
        builder: (dialogContext) => SimpleDialog(
          title: const Text('Choose category'),
          children: categories
              .map(
                (category) => SimpleDialogOption(
                  onPressed: () => Navigator.pop(dialogContext, category),
                  child: Text(category),
                ),
              )
              .toList(),
        ),
      );
      if (chosen == null) return;
      await homeService.categorizeAnalysisJob(
        retry.substring('analysis:'.length),
        chosen,
      );
      if (mounted) {
        setState(() {
          analysisJobs.remove(retry.substring('analysis:'.length));
          error = null;
          retryAction = null;
          message = 'Saved in $chosen without reading.';
        });
      }
    } on HomeServiceException catch (failure) {
      if (mounted) setState(() => error = failure.message);
    }
  }

  Future<void> dismissFailedAnalysis() async {
    final retry = retryAction;
    if (retry == null || !retry.startsWith('analysis:')) return;
    final id = retry.substring('analysis:'.length);
    try {
      await homeService.dismissAnalysisJob(id);
      if (mounted) {
        setState(() {
          analysisJobs.remove(id);
          error = null;
          retryAction = null;
          message = null;
        });
      }
    } on HomeServiceException catch (failure) {
      if (mounted) setState(() => error = failure.message);
    }
  }

  static String _mimeType(String name) {
    final extension = name.split('.').last.toLowerCase();
    return switch (extension) {
      'pdf' => 'application/pdf',
      'jpg' || 'jpeg' => 'image/jpeg',
      'png' => 'image/png',
      _ => 'application/octet-stream',
    };
  }

  Future<void> signOut() async {
    _stopAnalysisPolling();
    analysisJobs.clear();
    notifiedAnalysisJobs.clear();
    analysisRequestId = null;
    reminderRequestId = null;
    reminderInstruction = null;
    unresolvedCategory = null;
    categoryMatchAmbiguous = false;
    conversationController.clearLocal();
    analysisConversations.clear();
    destinationState.reset();
    tab = PrimaryDestination.home.index;
    setState(() => checking = true);
    await auth.signOut();
    if (mounted) setState(() => checking = false);
  }

  @override
  void dispose() {
    _stopAnalysisPolling();
    conversationController.removeListener(_conversationChanged);
    conversationController.dispose();
    destinationSubscription?.cancel();
    if (ownsDestinationState) destinationState.dispose();
    libraryNavigation.dispose();
    query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext c) => MaterialApp(
    navigatorKey: navigatorKey,
    title: 'FamilyDocuments',
    theme: ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff245b52)),
    ),
    home: checking
        ? const Scaffold(body: Center(child: Text('Checking your session…')))
        : auth.session == null
        ? Login(onSubmit: signIn, busy: signingIn, error: error)
        : Shell(
            tab: tab,
            onTab: _selectTab,
            timelineService: timelineService,
            libraryService: libraryService,
            libraryNavigation: libraryNavigation,
            inboxService: inboxService,
            analysisJobs: analysisJobs.values.toList(),
            onRefreshAnalysis: refreshAnalysisJobs,
            onRetryAnalysisJob: retryAnalysisJob,
            onSaveAnalysisWithoutReading: saveAnalysisWithoutReading,
            onChooseAnalysisCategory: chooseAnalysisCategory,
            onDismissAnalysisJob: saveAnalysisWithoutReading,
            onLibraryMetadataChanged: _invalidateDocumentResults,
            conversationMessages: conversationController.messages,
            conversationLoading: conversationController.loading,
            conversationConfirmation: conversationController.confirmation,
            onNewConversation: _newConversation,
            onConfirmConversation: conversationController.confirm,
            onCancelConversationConfirmation:
                conversationController.cancelConfirmation,
            onConversationSuggestion: conversationController.chooseSuggestion,
            query: query,
            busy: busy,
            message: message,
            error: error,
            searchResponse: searchResponse,
            organisedDocument: organisedDocument,
            suggestedDestination: suggestedDestination,
            unresolvedCategory: unresolvedCategory,
            categoryMatchAmbiguous: categoryMatchAmbiguous,
            linkCategories: pendingLinkCategories,
            unresolvedLinkCategory: unresolvedLinkCategory,
            uploadedName: uploadedName,
            onSend: send,
            onUpload: upload,
            onClearAttachment: clearAttachment,
            onSaveSuggestion: saveSuggestion,
            onCreateAndSaveCategory: createAndSaveCategory,
            onChooseUploadCategory: chooseUploadCategory,
            onCancelCategoryChoice: cancelCategoryChoice,
            onChooseLinkCategory: chooseLinkCategory,
            onCreateAndSaveLinkCategory: createAndSaveLinkCategory,
            onCancelLink: cancelLinkConversation,
            onRetry: retry,
            analysisFailure: retryAction?.startsWith('analysis:') ?? false,
            onSaveWithoutReading: saveFailedAnalysisWithoutReading,
            onChooseCategory: chooseFailedAnalysisCategory,
            onDismissAnalysis: dismissFailedAnalysis,
            onDiscussInbox: _discussInbox,
            email: auth.session!.email,
            onSignOut: signOut,
          ),
  );

  void _selectTab(int value) {
    if (value < 0 || value >= PrimaryDestination.values.length) return;
    setState(() => tab = value);
    destinationState.select(PrimaryDestination.values[value]);
  }

  void _invalidateDocumentResults() {
    if (!mounted) return;
    setState(() {
      searchResponse = null;
      organisedDocument = null;
    });
  }

  Future<void> _discussInbox(InboxMessage item) async {
    await conversationController.focusReference(
      ConversationReference(
        type: 'inbox',
        id: item.id,
        label: item.subject,
        metadata: {
          'review_state': item.reviewState,
          'updated_at': item.updatedAt.toUtc().toIso8601String(),
        },
      ),
    );
    _selectTab(PrimaryDestination.home.index);
  }
}

class Login extends StatefulWidget {
  const Login({
    super.key,
    required this.onSubmit,
    required this.busy,
    this.error,
  });
  final Future<void> Function(String, String) onSubmit;
  final bool busy;
  final String? error;
  @override
  State<Login> createState() => _LoginState();
}

class _LoginState extends State<Login> {
  final email = TextEditingController(), password = TextEditingController();
  @override
  Widget build(BuildContext c) => Scaffold(
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 380),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'FamilyDocuments',
                style: Theme.of(c).textTheme.headlineMedium,
              ),
              TextField(
                controller: email,
                decoration: const InputDecoration(labelText: 'Email'),
              ),
              TextField(
                controller: password,
                obscureText: true,
                decoration: const InputDecoration(labelText: 'Password'),
              ),
              if (widget.error != null)
                Text(widget.error!, style: const TextStyle(color: Colors.red)),
              FilledButton(
                onPressed: widget.busy
                    ? null
                    : () => widget.onSubmit(email.text, password.text),
                child: Text(widget.busy ? 'Signing in…' : 'Sign in'),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class Shell extends StatelessWidget {
  const Shell({
    super.key,
    required this.tab,
    required this.onTab,
    required this.timelineService,
    required this.libraryService,
    required this.libraryNavigation,
    required this.inboxService,
    required this.analysisJobs,
    required this.onRefreshAnalysis,
    required this.onRetryAnalysisJob,
    required this.onSaveAnalysisWithoutReading,
    required this.onChooseAnalysisCategory,
    required this.onDismissAnalysisJob,
    required this.onLibraryMetadataChanged,
    required this.conversationMessages,
    required this.conversationLoading,
    required this.conversationConfirmation,
    required this.onNewConversation,
    required this.onConfirmConversation,
    required this.onCancelConversationConfirmation,
    required this.onConversationSuggestion,
    required this.query,
    required this.busy,
    required this.message,
    required this.error,
    required this.searchResponse,
    required this.organisedDocument,
    required this.suggestedDestination,
    required this.unresolvedCategory,
    required this.categoryMatchAmbiguous,
    required this.linkCategories,
    required this.unresolvedLinkCategory,
    required this.uploadedName,
    required this.onSend,
    required this.onUpload,
    required this.onClearAttachment,
    required this.onSaveSuggestion,
    required this.onCreateAndSaveCategory,
    required this.onChooseUploadCategory,
    required this.onCancelCategoryChoice,
    required this.onChooseLinkCategory,
    required this.onCreateAndSaveLinkCategory,
    required this.onCancelLink,
    required this.onRetry,
    required this.analysisFailure,
    required this.onSaveWithoutReading,
    required this.onChooseCategory,
    required this.onDismissAnalysis,
    required this.onDiscussInbox,
    required this.email,
    required this.onSignOut,
  });
  final int tab;
  final ValueChanged<int> onTab;
  final TimelineService timelineService;
  final LibraryService libraryService;
  final LibraryNavigation libraryNavigation;
  final InboxService inboxService;
  final List<AnalysisJob> analysisJobs;
  final Future<void> Function() onRefreshAnalysis;
  final Future<void> Function(String) onRetryAnalysisJob;
  final Future<void> Function(String) onSaveAnalysisWithoutReading;
  final Future<void> Function(String) onChooseAnalysisCategory;
  final Future<void> Function(String) onDismissAnalysisJob;
  final VoidCallback onLibraryMetadataChanged;
  final List<ConversationMessage> conversationMessages;
  final bool conversationLoading;
  final ConversationConfirmation? conversationConfirmation;
  final Future<void> Function() onNewConversation;
  final Future<void> Function() onConfirmConversation;
  final Future<void> Function() onCancelConversationConfirmation;
  final Future<void> Function(ConversationSuggestion) onConversationSuggestion;
  final TextEditingController query;
  final bool busy;
  final String? message;
  final String? error;
  final SearchResponse? searchResponse;
  final OrganisedDocument? organisedDocument;
  final String? suggestedDestination;
  final String? unresolvedCategory;
  final bool categoryMatchAmbiguous;
  final List<SavedLinkCategory> linkCategories;
  final String? unresolvedLinkCategory;
  final String? uploadedName;
  final VoidCallback onSend,
      onUpload,
      onClearAttachment,
      onSaveSuggestion,
      onCreateAndSaveCategory,
      onChooseUploadCategory,
      onCancelCategoryChoice,
      onCreateAndSaveLinkCategory,
      onCancelLink,
      onRetry,
      onSaveWithoutReading,
      onChooseCategory,
      onDismissAnalysis;
  final ValueChanged<SavedLinkCategory> onChooseLinkCategory;
  final bool analysisFailure;
  final String email;
  final Future<void> Function() onSignOut;
  final ValueChanged<InboxMessage> onDiscussInbox;
  static const labels = ['Home', 'Timeline', 'Library', 'Inbox', 'Reminders'];
  static const icons = [
    Icons.home_outlined,
    Icons.schedule_outlined,
    Icons.folder_outlined,
    Icons.inbox_outlined,
    Icons.notifications_outlined,
  ];

  Widget profileMenu(BuildContext context) => PopupMenuButton<String>(
    key: const ValueKey('profile-avatar'),
    tooltip: 'Open profile menu',
    icon: CircleAvatar(
      radius: 20,
      backgroundColor: const Color(0xffdce8ff),
      foregroundColor: const Color(0xff245cc5),
      child: Text(_initials(email)),
    ),
    onSelected: (value) {
      if (value == 'signout') onSignOut();
      if (value == 'settings') {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => Scaffold(
              appBar: AppBar(title: const Text('Settings')),
              body: const Center(
                child: Text('Settings will be connected in Phase 2.'),
              ),
            ),
          ),
        );
      }
    },
    itemBuilder: (_) => const [
      PopupMenuItem(value: 'settings', child: Text('Settings')),
      PopupMenuItem(value: 'signout', child: Text('Sign out')),
    ],
  );

  @override
  Widget build(BuildContext c) {
    final wide = MediaQuery.sizeOf(c).width >= 720;
    final activeCount = analysisJobs.where((job) => !job.terminal).length;
    final content = switch (tab) {
      0 => Home(
        conversationMessages: conversationMessages,
        conversationLoading: conversationLoading,
        conversationConfirmation: conversationConfirmation,
        onNewConversation: onNewConversation,
        onConfirmConversation: onConfirmConversation,
        onCancelConversationConfirmation: onCancelConversationConfirmation,
        onConversationSuggestion: onConversationSuggestion,
        query: query,
        busy: busy,
        message: message,
        error: error,
        searchResponse: searchResponse,
        organisedDocument: organisedDocument,
        suggestedDestination: suggestedDestination,
        unresolvedCategory: unresolvedCategory,
        categoryMatchAmbiguous: categoryMatchAmbiguous,
        linkCategories: linkCategories,
        unresolvedLinkCategory: unresolvedLinkCategory,
        uploadedName: uploadedName,
        onSend: onSend,
        onUpload: onUpload,
        onClearAttachment: onClearAttachment,
        onSaveSuggestion: onSaveSuggestion,
        onCreateAndSaveCategory: onCreateAndSaveCategory,
        onChooseUploadCategory: onChooseUploadCategory,
        onCancelCategoryChoice: onCancelCategoryChoice,
        onChooseLinkCategory: onChooseLinkCategory,
        onCreateAndSaveLinkCategory: onCreateAndSaveLinkCategory,
        onCancelLink: onCancelLink,
        onRetry: onRetry,
        analysisFailure: analysisFailure,
        onSaveWithoutReading: onSaveWithoutReading,
        onChooseCategory: onChooseCategory,
        onDismissAnalysis: onDismissAnalysis,
      ),
      1 => TimelinePage(
        service: timelineService,
        processingJobs: analysisJobs,
        onRefreshProcessing: onRefreshAnalysis,
        onRetryJob: onRetryAnalysisJob,
        onSaveWithoutReading: onSaveAnalysisWithoutReading,
        onChooseCategory: onChooseAnalysisCategory,
        onDismissJob: onDismissAnalysisJob,
      ),
      2 => LibraryPage(
        service: libraryService,
        navigation: libraryNavigation,
        processingJobs: analysisJobs,
        onRefreshProcessing: onRefreshAnalysis,
        onMetadataChanged: onLibraryMetadataChanged,
      ),
      3 => InboxPage(
        service: inboxService,
        onDataChanged: onLibraryMetadataChanged,
        onOcrRequested: onRefreshAnalysis,
        onDiscuss: onDiscussInbox,
      ),
      _ => Center(child: Text('${labels[tab]} will be connected in Phase 2.')),
    };
    final main = Column(
      children: [
        Container(
          height: 72,
          padding: const EdgeInsets.symmetric(horizontal: 32),
          decoration: const BoxDecoration(
            color: Colors.white,
            border: Border(bottom: BorderSide(color: Color(0xffe3e8ef))),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  labels[tab],
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                    color: Color(0xff17233a),
                  ),
                ),
              ),
              if (activeCount > 0) ...[
                TextButton.icon(
                  key: const ValueKey('processing-indicator'),
                  onPressed: () => onTab(1),
                  icon: const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  label: Text(
                    '$activeCount document${activeCount == 1 ? '' : 's'} processing',
                  ),
                ),
                const SizedBox(width: 8),
              ],
              profileMenu(c),
            ],
          ),
        ),
        Expanded(child: content),
      ],
    );
    return Scaffold(
      backgroundColor: const Color(0xfffbfcfe),
      body: SafeArea(
        bottom: false,
        child: wide
            ? Row(
                children: [
                  _DesktopSidebar(
                    selected: tab,
                    onSelected: onTab,
                    email: email,
                  ),
                  Expanded(child: main),
                ],
              )
            : main,
      ),
      bottomNavigationBar: wide
          ? null
          : NavigationBar(
              selectedIndex: tab,
              onDestinationSelected: onTab,
              destinations: List.generate(
                5,
                (i) => NavigationDestination(
                  icon: Icon(icons[i]),
                  label: labels[i],
                ),
              ),
            ),
    );
  }

  static String _initials(String e) => e
      .split('@')
      .first
      .split(RegExp(r'[._ -]+'))
      .where((x) => x.isNotEmpty)
      .take(2)
      .map((x) => x[0].toUpperCase())
      .join();
}

class _DesktopSidebar extends StatelessWidget {
  const _DesktopSidebar({
    required this.selected,
    required this.onSelected,
    required this.email,
  });
  final int selected;
  final ValueChanged<int> onSelected;
  final String email;

  @override
  Widget build(BuildContext context) => Container(
    width: 238,
    padding: const EdgeInsets.fromLTRB(16, 24, 16, 18),
    decoration: const BoxDecoration(
      color: Colors.white,
      border: Border(right: BorderSide(color: Color(0xffe3e8ef))),
    ),
    child: Column(
      children: [
        const Row(
          children: [
            CircleAvatar(
              radius: 18,
              backgroundColor: Color(0xff123f78),
              foregroundColor: Colors.white,
              child: Text('F', style: TextStyle(fontWeight: FontWeight.w700)),
            ),
            SizedBox(width: 10),
            Expanded(
              child: Text(
                'FamilyDocuments',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ),
        const SizedBox(height: 30),
        ...List.generate(
          Shell.labels.length,
          (index) => Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Material(
              color: Colors.transparent,
              child: ListTile(
                selected: selected == index,
                selectedTileColor: const Color(0xffeaf0ff),
                selectedColor: const Color(0xff245cc5),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                leading: Icon(Shell.icons[index], size: 21),
                title: Text(Shell.labels[index]),
                onTap: () => onSelected(index),
              ),
            ),
          ),
        ),
        const Spacer(),
        const Divider(),
        ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 10),
          leading: CircleAvatar(
            radius: 18,
            backgroundColor: const Color(0xffdce8ff),
            child: Text(Shell._initials(email)),
          ),
          title: Text(
            email.split('@').first,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          subtitle: const Text('Family'),
        ),
      ],
    ),
  );
}

class Home extends StatelessWidget {
  const Home({
    super.key,
    required this.conversationMessages,
    required this.conversationLoading,
    required this.conversationConfirmation,
    required this.onNewConversation,
    required this.onConfirmConversation,
    required this.onCancelConversationConfirmation,
    required this.onConversationSuggestion,
    required this.query,
    required this.busy,
    required this.message,
    required this.error,
    required this.searchResponse,
    required this.organisedDocument,
    required this.suggestedDestination,
    required this.unresolvedCategory,
    required this.categoryMatchAmbiguous,
    required this.linkCategories,
    required this.unresolvedLinkCategory,
    required this.uploadedName,
    required this.onSend,
    required this.onUpload,
    required this.onClearAttachment,
    required this.onSaveSuggestion,
    required this.onCreateAndSaveCategory,
    required this.onChooseUploadCategory,
    required this.onCancelCategoryChoice,
    required this.onChooseLinkCategory,
    required this.onCreateAndSaveLinkCategory,
    required this.onCancelLink,
    required this.onRetry,
    required this.analysisFailure,
    required this.onSaveWithoutReading,
    required this.onChooseCategory,
    required this.onDismissAnalysis,
  });
  final List<ConversationMessage> conversationMessages;
  final bool conversationLoading;
  final ConversationConfirmation? conversationConfirmation;
  final Future<void> Function() onNewConversation;
  final Future<void> Function() onConfirmConversation;
  final Future<void> Function() onCancelConversationConfirmation;
  final Future<void> Function(ConversationSuggestion) onConversationSuggestion;
  final TextEditingController query;
  final bool busy;
  final String? message;
  final String? error;
  final SearchResponse? searchResponse;
  final OrganisedDocument? organisedDocument;
  final String? suggestedDestination;
  final String? unresolvedCategory;
  final bool categoryMatchAmbiguous;
  final List<SavedLinkCategory> linkCategories;
  final String? unresolvedLinkCategory;
  final String? uploadedName;
  final VoidCallback onSend,
      onUpload,
      onClearAttachment,
      onSaveSuggestion,
      onCreateAndSaveCategory,
      onChooseUploadCategory,
      onCancelCategoryChoice,
      onCreateAndSaveLinkCategory,
      onCancelLink,
      onRetry,
      onSaveWithoutReading,
      onChooseCategory,
      onDismissAnalysis;
  final ValueChanged<SavedLinkCategory> onChooseLinkCategory;
  final bool analysisFailure;
  @override
  Widget build(BuildContext c) => LayoutBuilder(
    builder: (context, constraints) {
      if (conversationMessages.isNotEmpty) {
        return _ActiveConversation(
          messages: conversationMessages,
          loading: conversationLoading,
          confirmation: conversationConfirmation,
          query: query,
          uploadedName: uploadedName,
          onNewConversation: onNewConversation,
          onConfirm: onConfirmConversation,
          onCancelConfirmation: onCancelConversationConfirmation,
          onSuggestion: onConversationSuggestion,
          onSend: onSend,
          onUpload: onUpload,
          onClearAttachment: onClearAttachment,
        );
      }
      final startingConversation =
          message == null &&
          searchResponse == null &&
          organisedDocument == null &&
          error == null;
      if (startingConversation) {
        return _InitialConversation(
          query: query,
          busy: busy,
          uploadedName: uploadedName,
          onSend: onSend,
          onUpload: onUpload,
          onClearAttachment: onClearAttachment,
        );
      }
      return Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 780),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 24, 20, 18),
            child: Column(
              children: [
                const Spacer(flex: 3),
                if (message == null &&
                    searchResponse == null &&
                    organisedDocument == null &&
                    error == null) ...[
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: const Color(0xff123f78),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: const Icon(Icons.auto_awesome, color: Colors.white),
                  ),
                  const SizedBox(height: 24),
                  const Text(
                    'What do you need?',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 30,
                      height: 1.15,
                      fontWeight: FontWeight.w700,
                      color: Color(0xff071a36),
                    ),
                  ),
                  const SizedBox(height: 10),
                  const Text(
                    'Add something or ask about anything you’ve saved.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 16, color: Color(0xff64748b)),
                  ),
                  const SizedBox(height: 24),
                ],
                if (message != null)
                  Container(
                    width: double.infinity,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      border: Border.all(color: const Color(0xffe3e8ef)),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(message!),
                          if (suggestedDestination != null) ...[
                            const SizedBox(height: 12),
                            Wrap(
                              spacing: 8,
                              children: [
                                FilledButton(
                                  onPressed: busy ? null : onSaveSuggestion,
                                  child: const Text('Save there'),
                                ),
                                OutlinedButton(
                                  onPressed: busy
                                      ? null
                                      : onChooseUploadCategory,
                                  child: const Text('Choose category'),
                                ),
                              ],
                            ),
                          ],
                          if (unresolvedCategory != null) ...[
                            const SizedBox(height: 12),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                if (!categoryMatchAmbiguous)
                                  FilledButton(
                                    onPressed: busy
                                        ? null
                                        : onCreateAndSaveCategory,
                                    child: const Text('Create and save'),
                                  ),
                                OutlinedButton(
                                  onPressed: busy
                                      ? null
                                      : onChooseUploadCategory,
                                  child: const Text('Choose another category'),
                                ),
                                TextButton(
                                  onPressed: busy
                                      ? null
                                      : onCancelCategoryChoice,
                                  child: const Text('Cancel'),
                                ),
                              ],
                            ),
                          ],
                          if (linkCategories.isNotEmpty &&
                              unresolvedLinkCategory == null) ...[
                            const SizedBox(height: 12),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                ...linkCategories.map(
                                  (category) => ActionChip(
                                    label: Text(category.name),
                                    onPressed: busy
                                        ? null
                                        : () => onChooseLinkCategory(category),
                                  ),
                                ),
                                TextButton(
                                  onPressed: busy ? null : onCancelLink,
                                  child: const Text('Cancel'),
                                ),
                              ],
                            ),
                          ],
                          if (unresolvedLinkCategory != null) ...[
                            const SizedBox(height: 12),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                FilledButton(
                                  onPressed: busy
                                      ? null
                                      : onCreateAndSaveLinkCategory,
                                  child: const Text('Create and save'),
                                ),
                                TextButton(
                                  onPressed: busy ? null : onCancelLink,
                                  child: const Text('Cancel'),
                                ),
                              ],
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                if (searchResponse != null)
                  _SearchResult(result: searchResponse!),
                if (organisedDocument != null)
                  _AnalysisResult(
                    result: organisedDocument!,
                    fileName: uploadedName,
                  ),
                if (error != null)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: const Color(0xfffff7f7),
                      border: Border.all(color: const Color(0xfff3c4c4)),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(
                              Icons.error_outline,
                              color: Color(0xffa72d2d),
                            ),
                            const SizedBox(width: 12),
                            Expanded(child: Text(error!)),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          runSpacing: 4,
                          children: [
                            TextButton(
                              onPressed: busy ? null : onRetry,
                              child: Text(
                                analysisFailure ? 'Retry reading' : 'Retry',
                              ),
                            ),
                            if (analysisFailure) ...[
                              TextButton(
                                onPressed: onSaveWithoutReading,
                                child: const Text('Save without reading'),
                              ),
                              TextButton(
                                onPressed: onChooseCategory,
                                child: const Text('Choose category'),
                              ),
                              TextButton(
                                onPressed: onDismissAnalysis,
                                child: const Text('Dismiss'),
                              ),
                            ],
                          ],
                        ),
                      ],
                    ),
                  ),
                if (message == null &&
                    searchResponse == null &&
                    organisedDocument == null &&
                    error == null &&
                    !busy)
                  const SizedBox(height: 8),
                const Spacer(flex: 5),
                if (busy)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 8),
                    child: Text('Working…'),
                  ),
                if (uploadedName != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: InputChip(
                        avatar: const Icon(Icons.attach_file, size: 18),
                        label: Text(uploadedName!),
                        onDeleted: onClearAttachment,
                      ),
                    ),
                  ),
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    border: Border.all(color: const Color(0xffcfd8e6)),
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: const [
                      BoxShadow(
                        color: Color(0x100f2748),
                        blurRadius: 24,
                        offset: Offset(0, 8),
                      ),
                    ],
                  ),
                  child: Row(
                    children: [
                      IconButton.filledTonal(
                        onPressed: onUpload,
                        tooltip: 'Upload document',
                        icon: const Icon(Icons.attach_file),
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: TextField(
                          controller: query,
                          onSubmitted: (_) => onSend(),
                          decoration: const InputDecoration(
                            hintText: 'Attach, save, or ask about anything…',
                            border: InputBorder.none,
                            filled: false,
                          ),
                        ),
                      ),
                      IconButton.filled(
                        onPressed: busy ? null : onSend,
                        tooltip: 'Send',
                        style: IconButton.styleFrom(
                          backgroundColor: const Color(0xff123f78),
                          foregroundColor: Colors.white,
                        ),
                        icon: const Icon(Icons.send_outlined),
                      ),
                    ],
                  ),
                ),
                if (message == null &&
                    searchResponse == null &&
                    organisedDocument == null &&
                    error == null &&
                    !busy) ...[
                  const SizedBox(height: 12),
                  Wrap(
                    alignment: WrapAlignment.center,
                    spacing: 8,
                    runSpacing: 8,
                    children:
                        [
                              'Add to Rental 1',
                              'Read this bill as an invoice',
                              'Add reminder Doctor appointment',
                            ]
                            .map(
                              (s) => ActionChip(
                                label: Text(s),
                                onPressed: () => query.text = s,
                              ),
                            )
                            .toList(),
                  ),
                ],
                const SizedBox(height: 10),
                const Text(
                  'Your documents stay private to your family.',
                  style: TextStyle(fontSize: 11, color: Color(0xff8190a5)),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}

class _ActiveConversation extends StatefulWidget {
  const _ActiveConversation({
    required this.messages,
    required this.loading,
    required this.confirmation,
    required this.query,
    required this.uploadedName,
    required this.onNewConversation,
    required this.onConfirm,
    required this.onCancelConfirmation,
    required this.onSuggestion,
    required this.onSend,
    required this.onUpload,
    required this.onClearAttachment,
  });

  final List<ConversationMessage> messages;
  final bool loading;
  final ConversationConfirmation? confirmation;
  final TextEditingController query;
  final String? uploadedName;
  final Future<void> Function() onNewConversation;
  final Future<void> Function() onConfirm;
  final Future<void> Function() onCancelConfirmation;
  final Future<void> Function(ConversationSuggestion) onSuggestion;
  final VoidCallback onSend, onUpload, onClearAttachment;

  @override
  State<_ActiveConversation> createState() => _ActiveConversationState();
}

class _ActiveConversationState extends State<_ActiveConversation> {
  final scroll = ScrollController();

  @override
  void didUpdateWidget(covariant _ActiveConversation oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.messages.length != oldWidget.messages.length ||
        widget.loading != oldWidget.loading) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && scroll.hasClients) {
          scroll.animateTo(
            scroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOut,
          );
        }
      });
    }
  }

  @override
  void dispose() {
    scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 820),
      child: SafeArea(
        top: false,
        child: Column(
          children: [
            Align(
              alignment: Alignment.centerRight,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: TextButton.icon(
                  onPressed: widget.loading ? null : widget.onNewConversation,
                  icon: const Icon(Icons.add_comment_outlined),
                  label: const Text('New conversation'),
                ),
              ),
            ),
            Expanded(
              child: ConversationTranscript(
                messages: widget.messages,
                loading: widget.loading,
                confirmation: widget.confirmation,
                onConfirm: widget.onConfirm,
                onCancelConfirmation: widget.onCancelConfirmation,
                onSuggestion: widget.onSuggestion,
                scrollController: scroll,
              ),
            ),
            if (widget.uploadedName != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: InputChip(
                    avatar: const Icon(Icons.attach_file, size: 18),
                    label: Text(widget.uploadedName!),
                    onDeleted: widget.onClearAttachment,
                  ),
                ),
              ),
            Padding(
              padding: EdgeInsets.fromLTRB(
                16,
                0,
                16,
                MediaQuery.viewInsetsOf(context).bottom > 0 ? 8 : 16,
              ),
              child: _ConversationComposer(
                query: widget.query,
                busy: widget.loading,
                onSend: widget.onSend,
                onUpload: widget.onUpload,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _InitialConversation extends StatelessWidget {
  const _InitialConversation({
    required this.query,
    required this.busy,
    required this.uploadedName,
    required this.onSend,
    required this.onUpload,
    required this.onClearAttachment,
  });
  final TextEditingController query;
  final bool busy;
  final String? uploadedName;
  final VoidCallback onSend, onUpload, onClearAttachment;

  @override
  Widget build(BuildContext context) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 780),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'What do you need?',
              style: TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.w600,
                color: Color(0xff071a36),
              ),
            ),
            const SizedBox(height: 28),
            if (uploadedName != null)
              Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: InputChip(
                    avatar: const Icon(Icons.attach_file, size: 18),
                    label: Text(uploadedName!),
                    onDeleted: onClearAttachment,
                  ),
                ),
              ),
            _ConversationComposer(
              query: query,
              busy: busy,
              onSend: onSend,
              onUpload: onUpload,
            ),
            const SizedBox(height: 26),
            ...[
              (Icons.link_outlined, 'Save this link https://example.com'),
              (Icons.receipt_long_outlined, 'Read this bill as an invoice'),
              (Icons.notifications_outlined, 'Add reminder Doctor appointment'),
            ].map(
              (example) => Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () => query.text = example.$2,
                  icon: Icon(
                    example.$1,
                    size: 19,
                    color: const Color(0xff64748b),
                  ),
                  label: Text(
                    example.$2,
                    style: const TextStyle(color: Color(0xff64748b)),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _ConversationComposer extends StatelessWidget {
  const _ConversationComposer({
    required this.query,
    required this.busy,
    required this.onSend,
    required this.onUpload,
  });
  final TextEditingController query;
  final bool busy;
  final VoidCallback onSend, onUpload;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(8),
    decoration: BoxDecoration(
      color: Colors.white,
      border: Border.all(color: const Color(0xffcfd8e6)),
      borderRadius: BorderRadius.circular(24),
      boxShadow: const [
        BoxShadow(
          color: Color(0x100f2748),
          blurRadius: 24,
          offset: Offset(0, 8),
        ),
      ],
    ),
    child: Row(
      children: [
        IconButton.filledTonal(
          onPressed: onUpload,
          tooltip: 'Attach a document',
          icon: const Icon(Icons.add),
        ),
        const SizedBox(width: 4),
        Expanded(
          child: TextField(
            controller: query,
            onSubmitted: (_) => onSend(),
            decoration: const InputDecoration(
              hintText: 'Attach, save, or ask about anything…',
              border: InputBorder.none,
              filled: false,
            ),
          ),
        ),
        IconButton.filled(
          onPressed: busy ? null : onSend,
          tooltip: 'Send',
          style: IconButton.styleFrom(
            backgroundColor: const Color(0xff123f78),
            foregroundColor: Colors.white,
          ),
          icon: const Icon(Icons.send_outlined),
        ),
      ],
    ),
  );
}

class _SearchResult extends StatelessWidget {
  const _SearchResult({required this.result});
  final SearchResponse result;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: Colors.white,
      border: Border.all(color: const Color(0xffe3e8ef)),
      borderRadius: BorderRadius.circular(16),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(result.answer),
        if (result.documents.isEmpty) ...[
          const SizedBox(height: 12),
          const Text(
            'No matching documents were found.',
            style: TextStyle(color: Color(0xff64748b)),
          ),
        ],
        ...result.documents.map(
          (document) => ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.description_outlined),
            title: Text(document.title),
            subtitle: Text(
              [
                document.collection,
                document.date,
              ].whereType<String>().join(' · '),
            ),
            trailing: const Text('Open'),
          ),
        ),
      ],
    ),
  );
}

class _AnalysisResult extends StatelessWidget {
  const _AnalysisResult({required this.result, this.fileName});
  final OrganisedDocument result;
  final String? fileName;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: Colors.white,
      border: Border.all(color: const Color(0xffe3e8ef)),
      borderRadius: BorderRadius.circular(16),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Row(
          children: [
            Icon(Icons.check_circle_outline, color: Color(0xff287a4d)),
            SizedBox(width: 8),
            Text(
              'Finished reading your document',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Text(result.title, style: const TextStyle(fontWeight: FontWeight.w700)),
        if (fileName != null && fileName != result.title) ...[
          const SizedBox(height: 2),
          Text(fileName!, style: const TextStyle(color: Color(0xff64748b))),
        ],
        const SizedBox(height: 4),
        const Text(
          'Saved and organised for your Family.',
          style: TextStyle(color: Color(0xff64748b)),
        ),
        const SizedBox(height: 12),
        const Text('Category', style: TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),
        Chip(label: Text(result.category)),
        const SizedBox(height: 8),
        const Text('Tags', style: TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),
        if (result.tags.isEmpty)
          const Text(
            'No tags added',
            style: TextStyle(color: Color(0xff64748b)),
          )
        else
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: result.tags
                .map((value) => Chip(label: Text(value)))
                .toList(),
          ),
      ],
    ),
  );
}
