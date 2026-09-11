import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/home/home_intent.dart';
import '../../core/home/reminder_parser.dart';
import 'data/conversation_service.dart';
import 'models/conversation_models.dart';

typedef ConversationOutcomeHandler = Future<void> Function(
  ConversationAuthoritativeOutcome outcome,
);

class ConversationController extends ChangeNotifier {
  ConversationController({
    required this._repository,
    this.onOutcome,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  static const maxMessages = 60;
  static const maxReferences = 12;

  final ConversationRepository _repository;
  final ConversationOutcomeHandler? onOutcome;
  final DateTime Function() _now;
  final List<ConversationMessage> _messages = [];
  final List<ConversationReference> _references = [];
  String? _conversationId;
  ConversationAction? _pendingClarification;
  String? _pendingClarificationId;
  ConversationConfirmation? _confirmation;
  bool _loading = false;
  bool _familySelectionRequired = false;
  List<ActiveFamilyChoice> _families = const [];
  String? _activeFamilyName;
  int _sequence = 0;

  List<ConversationMessage> get messages => List.unmodifiable(_messages);
  List<ConversationReference> get references => List.unmodifiable(_references);
  ConversationConfirmation? get confirmation => _confirmation;
  bool get loading => _loading;
  bool get started => _messages.isNotEmpty;
  bool get familySelectionRequired => _familySelectionRequired;
  List<ActiveFamilyChoice> get families => List.unmodifiable(_families);
  String get activeFamilyName => _activeFamilyName ?? 'Family';
  String? get conversationId => _conversationId;
  String? get pendingClarificationId => _pendingClarificationId;
  bool hasCorrelation(String correlationId) => _messages.any(
    (message) => message.data['correlation_id'] == correlationId,
  );

  Future<void> restore() async {
    _setLoading(true);
    try {
      final familyWorkspace = await _repository.activeFamilyWorkspace();
      _familySelectionRequired = familyWorkspace.selectionRequired;
      _families = familyWorkspace.families;
      _activeFamilyName = _families
          .where((family) => family.selected)
          .firstOrNull
          ?.name;
      _activeFamilyName ??= _families.length == 1
          ? _families.single.name
          : null;
      if (_familySelectionRequired) {
        _conversationId = null;
        _messages.clear();
        _confirmation = null;
        return;
      }
      final snapshot = await _repository.restore();
      _conversationId = snapshot.id;
      _messages
        ..clear()
        ..addAll(_collapse(snapshot.messages));
      _confirmation = snapshot.pendingConfirmation;
      _rebuildReferences();
      _restorePendingClarification();
    } finally {
      _setLoading(false);
    }
  }

  Future<void> selectFamily(String familyId) async {
    _setLoading(true);
    try {
      await _repository.selectActiveFamily(familyId);
      _familySelectionRequired = false;
      _conversationId = null;
      _messages.clear();
      _references.clear();
      _confirmation = null;
      await restore();
    } finally {
      _setLoading(false);
    }
  }

  Future<void> newConversation() async {
    _setLoading(true);
    try {
      _conversationId = await _repository.start(_newId('conversation'));
      _messages.clear();
      _references.clear();
      _pendingClarification = null;
      _pendingClarificationId = null;
      _confirmation = null;
      notifyListeners();
    } finally {
      _setLoading(false);
    }
  }

  void clearLocal() {
    _conversationId = null;
    _messages.clear();
    _references.clear();
    _pendingClarification = null;
    _pendingClarificationId = null;
    _confirmation = null;
    _loading = false;
    _familySelectionRequired = false;
    _families = const [];
    _activeFamilyName = null;
    notifyListeners();
  }

  Future<void> submit(
    String text, {
    bool hasAttachment = false,
    String? attachmentId,
    String? attachmentLabel,
    String? attachmentMimeType,
    List<int>? attachmentBytes,
  }) async {
    final message = text.trim();
    if (_loading || (message.isEmpty && !hasAttachment)) return;
    _setLoading(true);
    try {
      await _ensureConversation();
      if (hasAttachment && attachmentBytes != null) {
        attachmentId = await _repository.stageAttachment(
          conversationId: _conversationId!,
          fileName: attachmentLabel ?? 'document',
          mimeType: attachmentMimeType ?? 'application/pdf',
          bytes: attachmentBytes,
        );
      }
      await _append(
        ConversationMessage(
          id: _newId('user'),
          role: ConversationRole.user,
          kind: hasAttachment
              ? ConversationMessageKind.attachment
              : ConversationMessageKind.text,
          content: message.isEmpty ? 'Attached $attachmentLabel' : message,
          createdAt: _now(),
          data: {if (hasAttachment) 'attachment_label': attachmentLabel},
        ),
      );
      final deterministic = _deterministic(
        message,
        hasAttachment: hasAttachment,
        attachmentId: attachmentId,
        attachmentLabel: attachmentLabel,
      );
      ConversationAction action;
      if (_pendingClarification != null && _pendingClarificationId != null) {
        if (_asksForOptions(message)) {
          final outcome = await _repository.decideClarification(
            _pendingClarificationId!,
            decision: 'redisplay',
          );
          await _applyOutcome(outcome);
          return;
        }
        if (_isCancel(message)) {
          final outcome = await _repository.decideClarification(
            _pendingClarificationId!,
            decision: 'cancel',
          );
          await _applyOutcome(outcome);
          return;
        }
        final optionId = _optionIdForAnswer(message);
        if (optionId != null) {
          final outcome = await _repository.decideClarification(
            _pendingClarificationId!,
            decision: 'select',
            optionId: optionId,
          );
          await _applyOutcome(outcome);
          return;
        }
        if (deterministic != null) {
          await _supersedeClarification();
          action = deterministic;
        } else {
          action = _resolveClarification(message);
          await _supersedeClarification();
        }
      } else {
        action =
            deterministic ??
            await _modelOrClarification(
              message,
              hasAttachment,
              attachmentId: attachmentId,
            );
      }
      await _route(action);
    } on ConversationServiceException catch (error) {
      _showTransportFailure(error.message);
    } on Object {
      _showTransportFailure('FamilyDocuments could not be reached. Try again.');
    } finally {
      _setLoading(false);
    }
  }

  Future<void> chooseSuggestion(ConversationSuggestion suggestion) async {
    if (_loading) return;
    _setLoading(true);
    try {
      await _ensureConversation();
      _pendingClarification = null;
      _pendingClarificationId = null;
      await _route(suggestion.action);
    } on ConversationServiceException catch (error) {
      _showTransportFailure(error.message);
    } on Object {
      _showTransportFailure('FamilyDocuments could not be reached. Try again.');
    } finally {
      _setLoading(false);
    }
  }

  Future<void> chooseClarificationOption(
    ConversationClarificationOption option,
  ) async {
    final clarificationId = _pendingClarificationId;
    if (_loading || clarificationId == null) return;
    _setLoading(true);
    try {
      final outcome = await _repository.decideClarification(
        clarificationId,
        decision: 'select',
        optionId: option.id,
      );
      await _applyOutcome(outcome);
    } on ConversationServiceException catch (error) {
      _showTransportFailure(error.message);
    } finally {
      _setLoading(false);
    }
  }

  Future<void> cancelClarification() async {
    final clarificationId = _pendingClarificationId;
    if (_loading || clarificationId == null) return;
    _setLoading(true);
    try {
      final outcome = await _repository.decideClarification(
        clarificationId,
        decision: 'cancel',
      );
      await _applyOutcome(outcome);
    } on ConversationServiceException catch (error) {
      _showTransportFailure(error.message);
    } finally {
      _setLoading(false);
    }
  }

  Future<void> focusReference(ConversationReference reference) async {
    await _ensureConversation();
    _addReferences([reference]);
    await _append(
      ConversationMessage(
        id: _newId('user-context'),
        role: ConversationRole.user,
        kind: ConversationMessageKind.text,
        content: 'Discuss ${reference.label}',
        createdAt: _now(),
        data: {
          'references': [reference.toJson()],
        },
      ),
    );
    await _route(
      ConversationAction(
        id: _newId('action'),
        type: ConversationActionType.requestClarification,
        parameters: {
          'question': 'What would you like me to do with ${reference.label}?',
          'missing_parameter': 'reference_action',
        },
      ),
    );
  }

  Future<void> confirm() async {
    final pending = _confirmation;
    if (pending == null || _loading) return;
    _setLoading(true);
    try {
      final outcome = await _repository.decideConfirmation(
        pending.id,
        confirm: true,
      );
      await _applyOutcome(outcome);
    } on ConversationServiceException {
      _confirmation = null;
      await restore();
    } finally {
      _setLoading(false);
    }
  }

  Future<void> cancelConfirmation() async {
    final pending = _confirmation;
    if (pending == null || _loading) return;
    _setLoading(true);
    try {
      final outcome = await _repository.decideConfirmation(
        pending.id,
        confirm: false,
      );
      await _applyOutcome(outcome);
    } finally {
      _setLoading(false);
    }
  }

  Future<void> updateProgress({
    required String correlationId,
    required String text,
    required String status,
    Map<String, dynamic> data = const {},
    List<ConversationSuggestion> suggestions = const [],
  }) async {
    await _ensureConversation();
    final jobId = data['job_id']?.toString();
    if (jobId == null) return;
    if (_repository is MemoryConversationRepository) {
      _repository.recordSyntheticJobTransition(
        correlationId: correlationId,
        text: text,
        status: status,
        data: data,
        suggestions: suggestions,
      );
      await restore();
      return;
    }
    final transition = await _repository.recordJobTransition(
      _conversationId!,
      jobId,
    );
    if (transition['changed'] == true) await restore();
  }

  ConversationAction? _deterministic(
    String message, {
    required bool hasAttachment,
    String? attachmentId,
    String? attachmentLabel,
  }) {
    final lower = message.toLowerCase();
    final intent = parseHomeIntent(message, hasAttachment: hasAttachment);
    if (intent.type == HomeIntentType.greeting) {
      return ConversationAction(
        id: _newId('action'),
        type: ConversationActionType.unsupportedRequest,
        parameters: const {'reason': 'greeting'},
      );
    }
    if (_asksForOptions(message)) {
      return ConversationAction(
        id: _newId('action'),
        type: ConversationActionType.requestClarification,
        parameters: const {
          'question': 'What would you like to do?',
          'missing_parameter': 'intent',
        },
      );
    }
    if (hasAttachment) {
      if (intent.type == HomeIntentType.saveAttachment &&
          (intent.destination == null || intent.destination!.trim().isEmpty)) {
        return _attachmentClarification(
          attachmentId ?? 'current-attachment',
          attachmentLabel,
        );
      }
      return switch (intent.type) {
        HomeIntentType.saveAttachment => ConversationAction(
          id: _newId('action'),
          type: ConversationActionType.saveDocument,
          parameters: {
            'attachment_id': attachmentId ?? 'current-attachment',
            'category_name': intent.destination,
            'tags': <String>[],
          },
        ),
        HomeIntentType.readAttachment ||
        HomeIntentType.invoiceAttachment => ConversationAction(
          id: _newId('action'),
          type: ConversationActionType.requestDocumentOcr,
          parameters: {
            'attachment_id': attachmentId ?? 'current-attachment',
            'mode': intent.type == HomeIntentType.invoiceAttachment
                ? 'invoice'
                : 'document',
          },
        ),
        _ => _attachmentClarification(
          attachmentId ?? 'current-attachment',
          attachmentLabel,
        ),
      };
    }
    final reminderQuery = _reminderQuery(message);
    if (reminderQuery != null) {
      return ConversationAction(
        id: _newId('action'),
        type: ConversationActionType.queryReminders,
        parameters: reminderQuery,
      );
    }
    if (RegExp(
      r'^(?:read|scan) (?:it|that document|the document)(?: for ocr)?$',
      caseSensitive: false,
    ).hasMatch(message.trim())) {
      return _referenceAction(
        type: ConversationActionType.requestDocumentOcr,
        referenceType: 'document',
        parameterName: 'document_id',
        extra: const {'mode': 'document'},
      );
    }
    if (intent.type == HomeIntentType.search) {
      return ConversationAction(
        id: _newId('action'),
        type: ConversationActionType.searchFamilyContent,
        parameters: {'query': message},
      );
    }
    if (RegExp(
      r'^remind me (?:a|one) week before$',
      caseSensitive: false,
    ).hasMatch(message)) {
      final candidates = _references
          .where((reference) => reference.type == 'reminder')
          .toList();
      if (candidates.length == 1 &&
          candidates.single.metadata['due_date'] != null) {
        return ConversationAction(
          id: _newId('action'),
          type: ConversationActionType.updateReminder,
          parameters: {
            'reminder_id': candidates.single.id,
            'operation': 'one_week_before',
            'expected_due_date': candidates.single.metadata['due_date'],
          },
        );
      }
      return ConversationAction(
        id: _newId('action'),
        type: ConversationActionType.requestClarification,
        parameters: {
          'question': candidates.isEmpty ? 'Which reminder do you mean?' : 'I found more than one possible reminder. Which one do you mean?',
          'missing_parameter': 'reminder_id',
          'choices': candidates.take(3).map((item) => item.label).toList(),
        },
      );
    }
    if (intent.type == HomeIntentType.reminder) {
      try {
        final reminder = parseReminderCommand(message, now: _now().toUtc());
        return ConversationAction(
          id: _newId('action'),
          type: ConversationActionType.createReminder,
          parameters: {
            'title': reminder.title,
            'due_date': reminder.dueDate,
            if (reminder.dueTime != null) 'due_time': reminder.dueTime,
          },
        );
      } on ReminderClarification catch (clarification) {
        return ConversationAction(
          id: _newId('action'),
          type: ConversationActionType.requestClarification,
          parameters: {
            'question': clarification.message,
            'missing_parameter': 'reminder_date',
          },
        );
      }
    }
    if (intent.type == HomeIntentType.saveLink) {
      final category = RegExp(
        r'\b(?:in|under)\s+([a-z0-9][a-z0-9 &-]{0,39})(?:\s+https?://|$)',
        caseSensitive: false,
      ).firstMatch(message)?.group(1)?.trim();
      if (category != null) {
        return ConversationAction(
          id: _newId('action'),
          type: ConversationActionType.saveLink,
          parameters: {
            'url': intent.linkUrl,
            'title': intent.linkTitle,
            'category_name': category,
          },
        );
      }
      return ConversationAction(
        id: _newId('action'),
        type: ConversationActionType.requestClarification,
        parameters: {
          'question': 'Which category should I save this link in?',
          'missing_parameter': 'category_name',
          'link_url': intent.linkUrl,
          'link_title': intent.linkTitle,
        },
      );
    }
    final navigation = <String, String>{
      'home': 'home',
      'timeline': 'timeline',
      'library': 'library',
      'inbox': 'inbox',
      'reminders': 'reminders',
    };
    for (final entry in navigation.entries) {
      if (RegExp(
        '^(?:open|show|go to|view) ${RegExp.escape(entry.key)}\$',
        caseSensitive: false,
      ).hasMatch(message.trim())) {
        return ConversationAction(
          id: _newId('action'),
          type: ConversationActionType.openAppDestination,
          parameters: {'destination': entry.value},
        );
      }
    }
    final category = RegExp(
      r'^change (?:it|that|the document) to (.+)$',
      caseSensitive: false,
    ).firstMatch(message)?.group(1)?.trim();
    if (category != null) {
      return _referenceAction(
        type: ConversationActionType.updateDocumentCategory,
        referenceType: 'document',
        parameterName: 'document_id',
        extra: {'category_name': category},
      );
    }
    final addTag = RegExp(
      r'^add (?:the )?tag\s+(.+)$',
      caseSensitive: false,
    ).firstMatch(message)?.group(1)?.trim();
    if (addTag != null) {
      return _referenceAction(
        type: ConversationActionType.updateDocumentTags,
        referenceType: 'document',
        parameterName: 'document_id',
        extra: {
          'operation': 'add',
          'tags': [normaliseTag(addTag)],
        },
      );
    }
    final removeTag = RegExp(
      r'^remove (?:the )?tag\s+(.+)$',
      caseSensitive: false,
    ).firstMatch(message)?.group(1)?.trim();
    if (removeTag != null) {
      return _referenceAction(
        type: ConversationActionType.updateDocumentTags,
        referenceType: 'document',
        parameterName: 'document_id',
        extra: {
          'operation': 'remove',
          'tags': [normaliseTag(removeTag)],
        },
      );
    }
    if (RegExp(
      r'^(?:mark|set) (?:it|that|the message) (?:as )?reviewed$',
      caseSensitive: false,
    ).hasMatch(message.trim())) {
      return _referenceAction(
        type: ConversationActionType.markInboxReviewed,
        referenceType: 'inbox',
        parameterName: 'inbox_id',
        extra: const {},
      );
    }
    if (RegExp(
      r'^dismiss (?:it|that|the message)$',
      caseSensitive: false,
    ).hasMatch(message.trim())) {
      return _referenceAction(
        type: ConversationActionType.dismissInboxItem,
        referenceType: 'inbox',
        parameterName: 'inbox_id',
        extra: const {},
      );
    }
    final result = RegExp(
      r'^(?:open|show) (?:the )?(first|second|third|newest) (?:one|result)$',
      caseSensitive: false,
    ).firstMatch(message)?.group(1)?.toLowerCase();
    if (result != null) {
      final index = switch (result) {
        'second' => 1,
        'third' => 2,
        _ => 0,
      };
      if (_references.length > index) {
        return ConversationAction(
          id: _newId('action'),
          type: ConversationActionType.openAppDestination,
          parameters: {'destination': 'library', 'result_index': index},
        );
      }
    }
    if (RegExp(
      r'\b(weather|sports score|write code|tell me a joke|general knowledge)\b',
    ).hasMatch(lower)) {
      return ConversationAction(
        id: _newId('action'),
        type: ConversationActionType.unsupportedRequest,
        parameters: {'reason': 'outside_familydocuments'},
      );
    }
    return null;
  }

  ConversationAction _attachmentClarification(
    String attachmentId,
    String? attachmentLabel,
  ) {
    final category = metadataCategoryHint(attachmentLabel ?? '');
    final choiceActions = <ConversationAction>[
      if (category != null)
        ConversationAction(
          id: _newId('action'),
          type: ConversationActionType.saveDocument,
          parameters: {
            'attachment_id': attachmentId,
            'category_name': category,
            'tags': <String>[],
          },
        ),
      ConversationAction(
        id: _newId('action'),
        type: ConversationActionType.requestDocumentOcr,
        parameters: {'attachment_id': attachmentId, 'mode': 'document'},
      ),
    ];
    return ConversationAction(
      id: _newId('action'),
      type: ConversationActionType.requestClarification,
      parameters: {
        'question': category == null
            ? 'Which category should I use, or should I read the document first?'
            : 'This looks like it belongs in $category. Save it there or read it first?',
        'missing_parameter': category == null
            ? 'document_category'
            : 'attachment_action',
        'attachment_id': attachmentId,
        'tags': <String>[],
        'choices': [if (category != null) 'Save in $category', 'Read document'],
        'choice_actions': choiceActions
            .map((action) => action.toJson())
            .toList(),
      },
    );
  }

  ConversationAction _referenceAction({
    required ConversationActionType type,
    required String referenceType,
    required String parameterName,
    required Map<String, dynamic> extra,
  }) {
    final candidates = _references
        .where((reference) => reference.type == referenceType)
        .toList();
    if (candidates.length != 1) {
      return ConversationAction(
        id: _newId('action'),
        type: ConversationActionType.requestClarification,
        parameters: {
          'question': candidates.isEmpty
              ? 'Which $referenceType do you mean?'
              : 'I found more than one possible $referenceType. Which one do you mean?',
          'missing_parameter': parameterName,
          'choices': candidates.take(3).map((item) => item.label).toList(),
          'choice_actions': candidates.take(3).map((item) {
            final proposed = ConversationAction(
              id: _newId('action'),
              type: type,
              parameters: {
                parameterName: item.id,
                ...extra,
                if (type == ConversationActionType.updateDocumentCategory)
                  'ambiguous': true,
              },
            );
            return proposed.toJson();
          }).toList(),
        },
      );
    }
    return ConversationAction(
      id: _newId('action'),
      type: type,
      parameters: {parameterName: candidates.single.id, ...extra},
    );
  }

  ConversationAction _resolveClarification(String answer) {
    final pending = _pendingClarification!;
    _pendingClarification = null;
    if (pending.type == ConversationActionType.saveLink) {
      return ConversationAction(
        id: _newId('action'),
        type: pending.type,
        parameters: {...pending.parameters, 'category_name': answer.trim()},
      );
    }
    if (pending.type == ConversationActionType.requestClarification) {
      final missing = pending.parameters['missing_parameter']?.toString();
      if (missing == 'category_name' &&
          pending.parameters['link_url'] != null) {
        return ConversationAction(
          id: _newId('action'),
          type: ConversationActionType.saveLink,
          parameters: {
            'url': pending.parameters['link_url'],
            'title': pending.parameters['link_title'],
            'category_name': answer.trim(),
          },
        );
      }
      if (missing == 'document_category' &&
          pending.parameters['attachment_id'] != null) {
        final category = answer
            .trim()
            .replaceFirst(
              RegExp(
                r'^(?:save|put|add)(?: this)? in\s+',
                caseSensitive: false,
              ),
              '',
            )
            .trim();
        return ConversationAction(
          id: _newId('action'),
          type: ConversationActionType.saveDocument,
          parameters: {
            'attachment_id': pending.parameters['attachment_id'],
            'category_name': category,
            'tags': pending.parameters['tags'] ?? const <String>[],
          },
        );
      }
      final choiceActions = pending.parameters['choice_actions'];
      final labels = (pending.parameters['choices'] as List? ?? const [])
          .map((value) => value.toString())
          .toList();
      if (choiceActions is List && labels.length == choiceActions.length) {
        final normalised = answer.trim().toLowerCase();
        final selected = labels.indexWhere(
          (label) => label.trim().toLowerCase() == normalised,
        );
        if (selected >= 0 && choiceActions[selected] is Map) {
          return ConversationAction.fromJson(
            Map<String, dynamic>.from(choiceActions[selected] as Map),
          );
        }
      }
      if (missing == 'tags') {
        return _referenceAction(
          type: ConversationActionType.updateDocumentTags,
          referenceType: 'document',
          parameterName: 'document_id',
          extra: {
            'operation': 'add',
            'tags': [normaliseTag(answer)],
          },
        );
      }
      if (missing == 'change_category') {
        return _referenceAction(
          type: ConversationActionType.updateDocumentCategory,
          referenceType: 'document',
          parameterName: 'document_id',
          extra: {'category_name': answer.trim()},
        );
      }
      if (missing == 'search_query') {
        return ConversationAction(
          id: _newId('action'),
          type: ConversationActionType.searchFamilyContent,
          parameters: {'query': answer.trim()},
        );
      }
      if (missing == 'url' || missing == 'reminder') {
        final resolved = _deterministic(answer, hasAttachment: false);
        if (resolved != null) return resolved;
      }
      if (missing == 'reference_action') {
        final resolved = _deterministic(answer, hasAttachment: false);
        if (resolved != null) return resolved;
      }
      if (missing == 'attachment_action' &&
          RegExp(r'\bread\b', caseSensitive: false).hasMatch(answer)) {
        return ConversationAction(
          id: _newId('action'),
          type: ConversationActionType.requestDocumentOcr,
          parameters: {
            'attachment_id': 'current-attachment',
            'mode': 'document',
          },
        );
      }
    }
    return ConversationAction(
      id: _newId('action'),
      type: ConversationActionType.requestClarification,
      parameters: {
        'question': 'Please choose one of the options shown.',
        'missing_parameter': 'selection',
      },
    );
  }

  Future<void> _supersedeClarification() async {
    final id = _pendingClarificationId;
    _pendingClarification = null;
    _pendingClarificationId = null;
    if (id != null) {
      await _repository.decideClarification(id, decision: 'supersede');
    }
  }

  String? _optionIdForAnswer(String answer) {
    final actions = _pendingClarification?.parameters['choice_actions'];
    final labels =
        (_pendingClarification?.parameters['choices'] as List? ?? const [])
            .map((value) => value.toString())
            .toList();
    if (actions is! List || actions.length != labels.length) return null;
    final selected = labels.indexWhere(
      (label) => label.trim().toLowerCase() == answer.trim().toLowerCase(),
    );
    if (selected < 0 || actions[selected] is! Map) return null;
    return (actions[selected] as Map)['id']?.toString();
  }

  bool _asksForOptions(String message) => RegExp(
    r'^(?:what|which) options(?: are there)?[?!.]*$',
    caseSensitive: false,
  ).hasMatch(message.trim());

  bool _isCancel(String message) => RegExp(
    r'^(?:cancel|never mind|nevermind)[?!.]*$',
    caseSensitive: false,
  ).hasMatch(message.trim());

  Map<String, dynamic>? _reminderQuery(String message) {
    final text = message.trim();
    if (!RegExp(r'\breminders?\b', caseSensitive: false).hasMatch(text) ||
        RegExp(
          r'^(?:add|create|set|remind me)\b',
          caseSensitive: false,
        ).hasMatch(text)) {
      return null;
    }
    final lower = text.toLowerCase();
    if (RegExp(r'\boverdue\b').hasMatch(lower)) return {'scope': 'overdue'};
    if (RegExp(r'\btomorrow\b').hasMatch(lower)) return {'scope': 'tomorrow'};
    if (RegExp(r'\btoday\b').hasMatch(lower)) return {'scope': 'today'};
    final iso = RegExp(r'\b(\d{4}-\d{2}-\d{2})\b').firstMatch(lower)?.group(1);
    if (iso != null) return {'scope': 'date', 'date': iso};
    final named = RegExp(
      r'\b(\d{1,2})\s+(january|february|march|april|may|june|july|august|september|october|november|december)\s+(\d{4})\b',
    ).firstMatch(lower);
    if (named != null) {
      final month =
          const [
            'january',
            'february',
            'march',
            'april',
            'may',
            'june',
            'july',
            'august',
            'september',
            'october',
            'november',
            'december',
          ].indexOf(named.group(2)!) +
          1;
      final date = DateTime.utc(
        int.parse(named.group(3)!),
        month,
        int.parse(named.group(1)!),
      );
      if (date.year == int.parse(named.group(3)!) &&
          date.month == month &&
          date.day == int.parse(named.group(1)!)) {
        return {
          'scope': 'date',
          'date': date.toIso8601String().substring(0, 10),
        };
      }
    }
    return {'scope': 'upcoming'};
  }

  Future<ConversationAction> _modelOrClarification(
    String message,
    bool hasAttachment, {
    String? attachmentId,
  }) async {
    try {
      return await _repository.interpret(
        message: message,
        references: _references,
        hasAttachment: hasAttachment,
        attachmentId: attachmentId,
      );
    } on ConversationServiceException {
      return ConversationAction(
        id: _newId('action'),
        type: ConversationActionType.requestClarification,
        parameters: {
          'question': 'What would you like me to organise or find?',
          'missing_parameter': 'intent',
        },
      );
    }
  }

  Future<void> _route(ConversationAction action) async {
    action = await _prepareCategoryClarification(action);
    action.validate();
    final outcome = await _repository.submitAction(
      _conversationId!,
      action,
      action.id,
    );
    await _applyOutcome(outcome);
  }

  Future<ConversationAction> _prepareCategoryClarification(
    ConversationAction action,
  ) async {
    if (action.type != ConversationActionType.requestClarification ||
        action.parameters['missing_parameter'] != 'document_category') {
      return action;
    }
    final attachmentId = action.parameters['attachment_id']?.toString();
    if (attachmentId == null || _conversationId == null) return action;
    ConversationCategoryOptions options;
    try {
      options = await _repository.categoryOptions(
        conversationId: _conversationId!,
        attachmentId: attachmentId,
        fileName: action.parameters['attachment_label']?.toString() ?? '',
      );
    } on ConversationServiceException {
      return action;
    }
    final categoryActions = options.categories
        .take(2)
        .map(
          (category) => ConversationAction(
            id: _newId('action'),
            type: ConversationActionType.saveDocument,
            parameters: {
              'attachment_id': attachmentId,
              'category_name': category.name,
              'tags': action.parameters['tags'] ?? const <String>[],
            },
          ),
        );
    final readAction = ConversationAction(
      id: _newId('action'),
      type: ConversationActionType.requestDocumentOcr,
      parameters: {'attachment_id': attachmentId, 'mode': 'document'},
    );
    return ConversationAction(
      id: action.id,
      type: action.type,
      parameters: {
        ...action.parameters,
        'choices': [
          ...options.categories.take(2).map((category) => category.name),
          'Read document',
        ],
        'choice_actions': [
          ...categoryActions.map((item) => item.toJson()),
          readAction.toJson(),
        ],
      },
    );
  }

  Future<ConversationCategoryOptions> categoryOptionsForClarification() async {
    final pending = _pendingClarification;
    final attachmentId = pending?.parameters['attachment_id']?.toString();
    if (pending == null ||
        pending.parameters['missing_parameter'] != 'document_category' ||
        attachmentId == null ||
        _conversationId == null) {
      throw const ConversationServiceException(
        'That category choice is no longer available.',
      );
    }
    return _repository.categoryOptions(
      conversationId: _conversationId!,
      attachmentId: attachmentId,
      fileName: pending.parameters['attachment_label']?.toString() ?? '',
    );
  }

  Future<void> createCategoryAndSave(String name) async {
    final pending = _pendingClarification;
    final clarificationId = _pendingClarificationId;
    final attachmentId = pending?.parameters['attachment_id']?.toString();
    if (_loading ||
        pending == null ||
        clarificationId == null ||
        attachmentId == null) {
      return;
    }
    _setLoading(true);
    try {
      await _supersedeClarification();
      await _route(
        ConversationAction(
          id: _newId('action'),
          type: ConversationActionType.saveDocument,
          parameters: {
            'attachment_id': attachmentId,
            'category_name': name.trim(),
            'tags': pending.parameters['tags'] ?? const <String>[],
            'create_category': true,
          },
        ),
      );
    } on ConversationServiceException catch (error) {
      _showTransportFailure(error.message);
    } finally {
      _setLoading(false);
    }
  }

  Future<void> _applyOutcome(ConversationAuthoritativeOutcome outcome) async {
    await onOutcome?.call(outcome);
    final snapshot = await _repository.restore(_conversationId);
    _messages
      ..clear()
      ..addAll(_collapse(snapshot.messages));
    _confirmation = snapshot.pendingConfirmation ?? outcome.confirmation;
    _rebuildReferences();
    _restorePendingClarification();
    notifyListeners();
  }

  Future<void> _append(ConversationMessage message) async {
    _messages.add(message);
    if (_messages.length > maxMessages) {
      _messages.removeRange(0, _messages.length - maxMessages);
    }
    notifyListeners();
    await _repository.append(_conversationId!, message);
  }

  void _showTransportFailure(String message) {
    _messages.add(
      ConversationMessage(
        id: _newId('transport-error'),
        role: ConversationRole.assistant,
        kind: ConversationMessageKind.error,
        content: message,
        createdAt: _now(),
      ),
    );
    if (_messages.length > maxMessages) {
      _messages.removeRange(0, _messages.length - maxMessages);
    }
    notifyListeners();
  }

  Future<void> _ensureConversation() async {
    _conversationId ??= await _repository.start(_newId('conversation'));
  }

  void _addReferences(Iterable<ConversationReference> references) {
    for (final reference in references.toList().reversed) {
      _references.removeWhere(
        (existing) =>
            existing.type == reference.type && existing.id == reference.id,
      );
      _references.insert(0, reference);
    }
    if (_references.length > maxReferences) {
      _references.removeRange(maxReferences, _references.length);
    }
  }

  void _rebuildReferences() {
    _references.clear();
    for (final message in _messages) {
      final raw = message.data['references'];
      if (raw is! List) continue;
      _addReferences(
        raw.whereType<Map>().map(
          (value) =>
              ConversationReference.fromJson(Map<String, dynamic>.from(value)),
        ),
      );
    }
  }

  void _restorePendingClarification() {
    _pendingClarification = null;
    _pendingClarificationId = null;
    for (final message in _messages.reversed) {
      if (message.role != ConversationRole.assistant) continue;
      if (message.kind != ConversationMessageKind.clarification) return;
      final rawAction = message.data['action'];
      if (rawAction is! Map) continue;
      final parameters = rawAction['parameters'];
      if (parameters is! Map) continue;
      final proposed = parameters['proposed_action'];
      try {
        _pendingClarification = proposed is Map
            ? ConversationAction.fromJson(Map<String, dynamic>.from(proposed))
            : ConversationAction.fromJson(Map<String, dynamic>.from(rawAction));
        _pendingClarificationId = message.clarificationId;
      } on ConversationActionValidationException {
        if (message.clarificationId != null &&
            message.clarificationOptions.isNotEmpty) {
          _pendingClarification = ConversationAction(
            id: 'restored-clarification',
            type: ConversationActionType.requestClarification,
            parameters: {
              'question': message.content,
              'missing_parameter': 'selection',
            },
          );
          _pendingClarificationId = message.clarificationId;
        } else {
          _pendingClarification = null;
          _pendingClarificationId = null;
        }
      }
      return;
    }
  }

  List<ConversationMessage> _collapse(List<ConversationMessage> source) {
    final lastByCorrelation = <String, ConversationMessage>{};
    for (final message in source) {
      final correlation = message.data['correlation_id']?.toString();
      if (correlation != null) lastByCorrelation[correlation] = message;
    }
    return source
        .where((message) {
          final correlation = message.data['correlation_id']?.toString();
          return correlation == null ||
              identical(lastByCorrelation[correlation], message);
        })
        .take(maxMessages)
        .toList();
  }

  void _setLoading(bool value) {
    _loading = value;
    notifyListeners();
  }

  String _newId(String prefix) =>
      '$prefix-${_now().microsecondsSinceEpoch}-${_sequence++}';

  static String normaliseTag(String value) =>
      value.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();
}
