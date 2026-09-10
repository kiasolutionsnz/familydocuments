import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/home/home_intent.dart';
import '../../core/home/reminder_parser.dart';
import 'data/conversation_service.dart';
import 'models/conversation_models.dart';

typedef ConversationExecutor = Future<ConversationExecutionResult> Function(
  ConversationAction action,
);

class ConversationController extends ChangeNotifier {
  ConversationController({
    required this._repository,
    required this._execute,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  static const maxMessages = 60;
  static const maxReferences = 12;
  static const confirmationLifetime = Duration(minutes: 10);

  final ConversationRepository _repository;
  final ConversationExecutor _execute;
  final DateTime Function() _now;
  final List<ConversationMessage> _messages = [];
  final List<ConversationReference> _references = [];
  String? _conversationId;
  ConversationAction? _pendingClarification;
  ConversationConfirmation? _confirmation;
  bool _loading = false;
  int _sequence = 0;

  List<ConversationMessage> get messages => List.unmodifiable(_messages);
  List<ConversationReference> get references => List.unmodifiable(_references);
  ConversationConfirmation? get confirmation => _confirmation;
  bool get loading => _loading;
  bool get started => _messages.isNotEmpty;
  String? get conversationId => _conversationId;
  bool hasCorrelation(String correlationId) => _messages.any(
    (message) => message.data['correlation_id'] == correlationId,
  );

  Future<void> restore() async {
    _setLoading(true);
    try {
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

  Future<void> newConversation() async {
    _setLoading(true);
    try {
      _conversationId = await _repository.start(_newId('conversation'));
      _messages.clear();
      _references.clear();
      _pendingClarification = null;
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
    _confirmation = null;
    _loading = false;
    notifyListeners();
  }

  Future<void> submit(
    String text, {
    bool hasAttachment = false,
    String? attachmentId,
    String? attachmentLabel,
  }) async {
    final message = text.trim();
    if (_loading || (message.isEmpty && !hasAttachment)) return;
    _setLoading(true);
    try {
      await _ensureConversation();
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
      ConversationAction action;
      if (_pendingClarification != null) {
        action = _resolveClarification(message);
      } else {
        action =
            _deterministic(
              message,
              hasAttachment: hasAttachment,
              attachmentId: attachmentId,
              attachmentLabel: attachmentLabel,
            ) ??
            await _modelOrClarification(message, hasAttachment);
      }
      await _route(action);
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
      await _route(suggestion.action);
    } finally {
      _setLoading(false);
    }
  }

  Future<void> focusReference(ConversationReference reference) async {
    await _ensureConversation();
    _addReferences([reference]);
    await _assistant(
      'What would you like me to do with ${reference.label}?',
      data: {
        'references': [reference.toJson()],
      },
      suggestions: reference.type == 'inbox'
          ? [
              ConversationSuggestion(
                label: 'Mark reviewed',
                action: ConversationAction(
                  id: _newId('action'),
                  type: ConversationActionType.markInboxReviewed,
                  parameters: {'inbox_id': reference.id},
                ),
              ),
              ConversationSuggestion(
                label: 'Dismiss',
                action: ConversationAction(
                  id: _newId('action'),
                  type: ConversationActionType.dismissInboxItem,
                  parameters: {'inbox_id': reference.id},
                ),
              ),
            ]
          : const [],
    );
  }

  Future<void> confirm() async {
    final pending = _confirmation;
    if (pending == null || _loading) return;
    if (!pending.expiresAt.isAfter(_now())) {
      _confirmation = null;
      await _assistant(
        'That confirmation has expired. Please ask me to prepare the change again.',
        kind: ConversationMessageKind.error,
      );
      return;
    }
    _setLoading(true);
    try {
      await _repository.consumeConfirmation(
        _conversationId!,
        pending.action.id,
        cancel: false,
      );
      _confirmation = null;
      await _executeAction(pending.action);
    } on ConversationServiceException catch (failure) {
      _confirmation = null;
      await _assistant(failure.message, kind: ConversationMessageKind.error);
    } finally {
      _setLoading(false);
    }
  }

  Future<void> cancelConfirmation() async {
    final pending = _confirmation;
    if (pending == null || _loading) return;
    _setLoading(true);
    try {
      await _repository.consumeConfirmation(
        _conversationId!,
        pending.action.id,
        cancel: true,
      );
      _confirmation = null;
      await _repository.recordAction(
        _conversationId!,
        pending.action,
        status: 'cancelled',
      );
      await _assistant('Okay, I didn’t make that change.');
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
    final message = ConversationMessage(
      id: _newId('progress'),
      role: ConversationRole.assistant,
      kind: status == 'failed'
          ? ConversationMessageKind.error
          : status == 'finished'
          ? ConversationMessageKind.result
          : ConversationMessageKind.progress,
      content: text,
      createdAt: _now(),
      data: {'correlation_id': correlationId, 'status': status, ...data},
      suggestions: suggestions.take(3).toList(),
    );
    _messages.removeWhere(
      (existing) => existing.data['correlation_id'] == correlationId,
    );
    await _append(message);
  }

  ConversationAction? _deterministic(
    String message, {
    required bool hasAttachment,
    String? attachmentId,
    String? attachmentLabel,
  }) {
    final lower = message.toLowerCase();
    final intent = parseHomeIntent(message, hasAttachment: hasAttachment);
    if (hasAttachment) {
      if (intent.type == HomeIntentType.saveAttachment &&
          (intent.destination == null || intent.destination!.trim().isEmpty)) {
        return ConversationAction(
          id: _newId('action'),
          type: ConversationActionType.requestClarification,
          parameters: {
            'question': 'Which category should I save this document in?',
            'missing_parameter': 'document_category',
            'attachment_id': attachmentId ?? 'current-attachment',
            'tags': <String>[],
          },
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
            'request_id': _newId('reminder'),
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
            'request_id': _newId('link'),
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
              parameters: {parameterName: item.id, ...extra},
            );
            return ConversationAction(
              id: _newId('action'),
              type: ConversationActionType.requestConfirmation,
              parameters: {
                'summary': 'Use ${item.label} for this action?',
                'target_label': item.label,
                'proposed_action': proposed.toJson(),
              },
            ).toJson();
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
        id: pending.id,
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
            'request_id': _newId('link'),
          },
        );
      }
      if (missing == 'document_category' &&
          pending.parameters['attachment_id'] != null) {
        return ConversationAction(
          id: _newId('action'),
          type: ConversationActionType.saveDocument,
          parameters: {
            'attachment_id': pending.parameters['attachment_id'],
            'category_name': answer.trim(),
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

  Future<ConversationAction> _modelOrClarification(
    String message,
    bool hasAttachment,
  ) async {
    try {
      return await _repository.interpret(
        message: message,
        references: _references,
        hasAttachment: hasAttachment,
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
    action.validate();
    if (action.type == ConversationActionType.requestConfirmation) {
      final proposed = ConversationAction.fromJson(
        Map<String, dynamic>.from(action.parameters['proposed_action'] as Map),
      );
      final confirmation = ConversationConfirmation(
        action: proposed,
        summary:
            action.parameters['summary']?.toString() ??
            _confirmationSummary(proposed),
        targetLabel:
            action.parameters['target_label']?.toString() ??
            _targetLabel(proposed),
        expiresAt: _now().add(confirmationLifetime),
      );
      await _repository.saveConfirmation(_conversationId!, confirmation);
      _confirmation = confirmation;
      await _assistant(
        confirmation.summary,
        kind: ConversationMessageKind.confirmation,
        data: {
          'action': proposed.toJson(),
          'target_label': confirmation.targetLabel,
          'expires_at': confirmation.expiresAt.toUtc().toIso8601String(),
        },
      );
      return;
    }
    if (action.type == ConversationActionType.requestClarification) {
      final proposed = action.parameters['proposed_action'];
      _pendingClarification = proposed is Map
          ? ConversationAction.fromJson(Map<String, dynamic>.from(proposed))
          : action;
      final choiceActions = action.parameters['choice_actions'];
      final choices = action.parameters['choices'];
      final suggestions = <ConversationSuggestion>[];
      if (choiceActions is List && choices is List) {
        for (
          var index = 0;
          index < choiceActions.length && index < choices.length;
          index++
        ) {
          final raw = choiceActions[index];
          if (raw is Map) {
            suggestions.add(
              ConversationSuggestion(
                label: choices[index].toString(),
                action: ConversationAction.fromJson(
                  Map<String, dynamic>.from(raw),
                ),
              ),
            );
          }
        }
      }
      await _assistant(
        action.parameters['question']?.toString() ??
            'What would you like me to do?',
        kind: ConversationMessageKind.clarification,
        data: {'action': action.toJson()},
        suggestions: suggestions,
      );
      return;
    }
    if (action.type == ConversationActionType.unsupportedRequest) {
      await _assistant(
        'I can help organise and find information in your FamilyDocuments account.',
        kind: ConversationMessageKind.text,
        suggestions: _supportedSuggestions(),
      );
      return;
    }
    if (_needsConfirmation(action)) {
      final confirmation = ConversationConfirmation(
        action: action,
        summary: _confirmationSummary(action),
        targetLabel: _targetLabel(action),
        expiresAt: _now().add(confirmationLifetime),
      );
      await _repository.saveConfirmation(_conversationId!, confirmation);
      _confirmation = confirmation;
      await _assistant(
        confirmation.summary,
        kind: ConversationMessageKind.confirmation,
        data: {
          'action': action.toJson(),
          'target_label': confirmation.targetLabel,
          'expires_at': confirmation.expiresAt.toUtc().toIso8601String(),
        },
      );
      return;
    }
    await _executeAction(action);
  }

  Future<void> _executeAction(ConversationAction action) async {
    try {
      final result = await _execute(action);
      _addReferences(result.references);
      await _repository.recordAction(
        _conversationId!,
        action,
        status: 'succeeded',
        targetType: result.references.length == 1
            ? result.references.single.type
            : null,
        targetId: result.references.length == 1
            ? result.references.single.id
            : null,
        result: {
          'result_type': action.type.wireName,
          'reference_count': result.references.length,
        },
      );
      await _assistant(
        result.message,
        kind: ConversationMessageKind.result,
        data: {
          ...result.data,
          'references': result.references.map((item) => item.toJson()).toList(),
        },
        suggestions: result.suggestions.take(3).toList(),
      );
    } catch (failure) {
      try {
        await _repository.recordAction(
          _conversationId!,
          action,
          status: 'failed',
          result: {'failure_category': failure.runtimeType.toString()},
        );
      } catch (_) {}
      await _assistant(
        _safeFailure(failure),
        kind: ConversationMessageKind.error,
        suggestions: [
          ConversationSuggestion(
            label: 'Try again',
            action: ConversationAction(
              id: _newId('retry'),
              type: action.type,
              parameters: action.parameters,
            ),
          ),
        ],
      );
    }
  }

  bool _needsConfirmation(ConversationAction action) {
    if (action.type == ConversationActionType.saveDocument &&
        action.parameters['create_category'] == true) {
      return true;
    }
    if (action.type == ConversationActionType.saveLink &&
        action.parameters['create_category'] == true) {
      return true;
    }
    if (action.type == ConversationActionType.dismissInboxItem ||
        action.type == ConversationActionType.updateReminder) {
      return true;
    }
    if (action.type == ConversationActionType.updateDocumentTags &&
        action.parameters['operation'] == 'remove') {
      return true;
    }
    return action.type == ConversationActionType.updateDocumentCategory &&
        action.parameters['ambiguous'] == true;
  }

  String _confirmationSummary(
    ConversationAction action,
  ) => switch (action.type) {
    ConversationActionType.dismissInboxItem =>
      'Dismiss this Inbox item? It will no longer appear in Inbox.',
    ConversationActionType.updateReminder =>
      'Update this reminder as requested?',
    ConversationActionType.updateDocumentTags =>
      'Remove ${((action.parameters['tags'] as List?) ?? const []).join(', ')} from this document?',
    ConversationActionType.updateDocumentCategory =>
      'Change this document’s category to ${action.parameters['category_name']}?',
    ConversationActionType.saveDocument =>
      'Create ${action.parameters['category_name']} and save this document there?',
    ConversationActionType.saveLink =>
      'Create ${action.parameters['category_name']} and save this link there?',
    _ => 'Confirm this action?',
  };

  String _targetLabel(ConversationAction action) {
    for (final key in const [
      'document_id',
      'reminder_id',
      'inbox_id',
      'link_id',
    ]) {
      final id = action.parameters[key]?.toString();
      if (id == null) continue;
      for (final reference in _references) {
        if (reference.id == id) return reference.label;
      }
    }
    return 'Selected item';
  }

  List<ConversationSuggestion> _supportedSuggestions() => [
    ConversationSuggestion(
      label: 'Find a document',
      action: ConversationAction(
        id: _newId('suggestion'),
        type: ConversationActionType.requestClarification,
        parameters: {
          'question': 'What document should I find?',
          'missing_parameter': 'search_query',
        },
      ),
    ),
    ConversationSuggestion(
      label: 'Save a link',
      action: ConversationAction(
        id: _newId('suggestion'),
        type: ConversationActionType.requestClarification,
        parameters: {
          'question': 'Paste the link you would like to save.',
          'missing_parameter': 'url',
        },
      ),
    ),
    ConversationSuggestion(
      label: 'Create a reminder',
      action: ConversationAction(
        id: _newId('suggestion'),
        type: ConversationActionType.requestClarification,
        parameters: {
          'question': 'What should I remind you about, and when?',
          'missing_parameter': 'reminder',
        },
      ),
    ),
  ];

  Future<void> _assistant(
    String content, {
    ConversationMessageKind kind = ConversationMessageKind.text,
    Map<String, dynamic> data = const {},
    List<ConversationSuggestion> suggestions = const [],
  }) => _append(
    ConversationMessage(
      id: _newId('assistant'),
      role: ConversationRole.assistant,
      kind: kind,
      content: content,
      createdAt: _now(),
      data: data,
      suggestions: suggestions.take(3).toList(),
    ),
  );

  Future<void> _append(ConversationMessage message) async {
    _messages.add(message);
    if (_messages.length > maxMessages) {
      _messages.removeRange(0, _messages.length - maxMessages);
    }
    notifyListeners();
    await _repository.append(_conversationId!, message);
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
    for (final message in _messages.reversed) {
      if (message.kind != ConversationMessageKind.clarification) continue;
      final rawAction = message.data['action'];
      if (rawAction is! Map) continue;
      final parameters = rawAction['parameters'];
      if (parameters is! Map) continue;
      final proposed = parameters['proposed_action'];
      try {
        _pendingClarification = proposed is Map
            ? ConversationAction.fromJson(Map<String, dynamic>.from(proposed))
            : ConversationAction.fromJson(Map<String, dynamic>.from(rawAction));
      } on ConversationActionValidationException {
        _pendingClarification = null;
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

  static String _safeFailure(Object failure) {
    final message = failure.toString();
    if (message.contains('no longer have access') ||
        message.contains('not authorised') ||
        message.contains('permission')) {
      return 'You no longer have permission to change that item.';
    }
    return 'That action could not be completed. Nothing was changed.';
  }
}
