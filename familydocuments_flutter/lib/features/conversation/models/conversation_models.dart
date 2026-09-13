import '../../../core/security/public_https_url.dart';

enum ConversationRole { user, assistant }

enum ConversationMessageKind {
  text,
  attachment,
  clarification,
  confirmation,
  progress,
  result,
  error,
}

enum ConversationActionType {
  searchFamilyContent('search_family_content'),
  queryReminders('query_reminders'),
  saveDocument('save_document'),
  recordRentalExpense('record_rental_expense'),
  requestDocumentOcr('request_document_ocr'),
  updateDocumentCategory('update_document_category'),
  updateDocumentTags('update_document_tags'),
  createReminder('create_reminder'),
  updateReminder('update_reminder'),
  saveLink('save_link'),
  markInboxReviewed('mark_inbox_reviewed'),
  dismissInboxItem('dismiss_inbox_item'),
  openAppDestination('open_app_destination'),
  requestClarification('request_clarification'),
  requestConfirmation('request_confirmation'),
  unsupportedRequest('unsupported_request');

  const ConversationActionType(this.wireName);
  final String wireName;

  static ConversationActionType? fromWireName(String value) {
    for (final type in values) {
      if (type.wireName == value) return type;
    }
    return null;
  }
}

class ConversationActionValidationException implements Exception {
  const ConversationActionValidationException(this.message);
  final String message;
}

class ConversationAction {
  ConversationAction({
    required this.id,
    required this.type,
    required Map<String, dynamic> parameters,
    this.version = 1,
  }) : parameters = Map.unmodifiable(parameters) {
    validate();
  }

  factory ConversationAction.fromJson(Map<String, dynamic> json) {
    _expectKeys(json, const {'id', 'type', 'version', 'parameters'});
    final type = ConversationActionType.fromWireName(
      json['type']?.toString() ?? '',
    );
    if (type == null) {
      throw const ConversationActionValidationException('Unknown action.');
    }
    final raw = json['parameters'];
    if (raw is! Map) {
      throw const ConversationActionValidationException(
        'Action parameters must be an object.',
      );
    }
    return ConversationAction(
      id: json['id']?.toString() ?? '',
      type: type,
      version: (json['version'] as num?)?.toInt() ?? 0,
      parameters: Map<String, dynamic>.from(raw),
    );
  }

  final String id;
  final ConversationActionType type;
  final int version;
  final Map<String, dynamic> parameters;

  Map<String, dynamic> toJson() => {
    'id': id,
    'type': type.wireName,
    'version': version,
    'parameters': parameters,
  };

  void validate() {
    if (version != 1 || !_actionId.hasMatch(id)) {
      throw const ConversationActionValidationException(
        'Invalid action identifier or version.',
      );
    }
    final allowed = _allowedParameters[type]!;
    _expectKeys(parameters, allowed);
    if (type == ConversationActionType.recordRentalExpense) {
      for (final key in allowed.difference({'create_property'})) {
        final value = parameters[key];
        if (value != null && value is! String) {
          throw ConversationActionValidationException('$key must be text.');
        }
      }
      if ((parameters['attachment_id'] != null &&
              parameters['document_id'] != null) ||
          (parameters['property_id'] != null &&
              parameters['create_property'] == true)) {
        throw const ConversationActionValidationException('Choose one target.');
      }
      final amount = parameters['amount'];
      final currency = parameters['currency'];
      if ((amount != null &&
              !RegExp(r'^[0-9]{1,10}(\.[0-9]{1,2})?$')
                  .hasMatch(amount as String)) ||
          (currency != null &&
              !RegExp(r'^[A-Z]{3}$').hasMatch(currency as String))) {
        throw const ConversationActionValidationException(
          'Enter a valid amount and currency.',
        );
      }
    }
    for (final key in _requiredParameters[type] ?? const <String>{}) {
      final value = parameters[key];
      if (value == null || (value is String && value.trim().isEmpty)) {
        throw ConversationActionValidationException(
          'Missing required parameter: $key.',
        );
      }
    }
    if (type == ConversationActionType.requestDocumentOcr &&
        parameters['attachment_id'] == null &&
        parameters['document_id'] == null) {
      throw const ConversationActionValidationException(
        'Reading requires an attachment or document.',
      );
    }
    for (final entry in parameters.entries) {
      if (entry.value is String && (entry.value as String).length > 500) {
        throw const ConversationActionValidationException(
          'Action parameter is too long.',
        );
      }
    }
    for (final key in const [
      'query',
      'attachment_id',
      'category_name',
      'category_id',
      'document_id',
      'reminder_id',
      'link_id',
      'inbox_id',
      'mode',
      'operation',
      'title',
      'due_date',
      'due_time',
      'expected_due_date',
      'expected_updated_at',
      'url',
      'destination',
      'question',
      'missing_parameter',
      'summary',
      'target_label',
      'reason',
      'link_url',
      'link_title',
      'recurrence',
      'scope',
      'date',
      'draft_title',
      'draft_date',
      'draft_time',
    ]) {
      final value = parameters[key];
      if (value != null && value is! String) {
        throw ConversationActionValidationException('$key must be text.');
      }
    }
    for (final key in const [
      'create_category',
      'ambiguous',
      'create_property',
    ]) {
      final value = parameters[key];
      if (value != null && value is! bool) {
        throw ConversationActionValidationException(
          '$key must be true or false.',
        );
      }
    }
    final resultIndex = parameters['result_index'];
    if (resultIndex != null &&
        (resultIndex is! int || resultIndex < 0 || resultIndex > 2)) {
      throw const ConversationActionValidationException(
        'Invalid result selection.',
      );
    }
    for (final key in const [
      'document_id',
      'reminder_id',
      'link_id',
      'inbox_id',
      'category_id',
    ]) {
      final value = parameters[key];
      if (value != null && !_uuid.hasMatch(value.toString())) {
        throw ConversationActionValidationException('Malformed $key.');
      }
    }
    final destination = parameters['destination']?.toString();
    if (destination != null &&
        !const {
          'home',
          'timeline',
          'library',
          'inbox',
          'reminders',
        }.contains(destination)) {
      throw const ConversationActionValidationException(
        'Unsupported destination.',
      );
    }
    final url = parameters['url']?.toString();
    if (url != null) {
      final parsed = Uri.tryParse(url);
      if (parsed == null || !isPublicHttpsUrl(url)) {
        throw const ConversationActionValidationException('Invalid link URL.');
      }
    }
    final date = parameters['due_date']?.toString();
    if (date != null && !_validDate(date)) {
      throw const ConversationActionValidationException('Invalid date.');
    }
    final expectedDate = parameters['expected_due_date']?.toString();
    if (expectedDate != null && !_validDate(expectedDate)) {
      throw const ConversationActionValidationException('Invalid date.');
    }
    final draftDate = parameters['draft_date']?.toString();
    if (draftDate != null && !_validDate(draftDate)) {
      throw const ConversationActionValidationException('Invalid draft date.');
    }
    final draftTime = parameters['draft_time']?.toString();
    if (draftTime != null && !_time.hasMatch(draftTime)) {
      throw const ConversationActionValidationException('Invalid draft time.');
    }
    final time = parameters['due_time']?.toString();
    if (time != null && !_time.hasMatch(time)) {
      throw const ConversationActionValidationException('Invalid time.');
    }
    final tags = parameters['tags'];
    if (tags != null &&
        (tags is! List ||
            tags.length > 12 ||
            tags.any((tag) => tag is! String))) {
      throw const ConversationActionValidationException('Invalid tags.');
    }
    final choices = parameters['choices'];
    if (choices != null &&
        (choices is! List ||
            choices.length > 3 ||
            choices.any((choice) => choice is! String))) {
      throw const ConversationActionValidationException(
        'Invalid clarification choices.',
      );
    }
    final operation = parameters['operation']?.toString();
    if (type == ConversationActionType.updateDocumentTags &&
        !const {'add', 'remove'}.contains(operation)) {
      throw const ConversationActionValidationException(
        'Unsupported tag operation.',
      );
    }
    if (type == ConversationActionType.updateReminder &&
        operation != 'one_week_before') {
      throw const ConversationActionValidationException(
        'Unsupported reminder operation.',
      );
    }
    final mode = parameters['mode']?.toString();
    if (type == ConversationActionType.requestDocumentOcr &&
        !const {'document', 'invoice'}.contains(mode)) {
      throw const ConversationActionValidationException(
        'Unsupported reading mode.',
      );
    }
    final proposed = parameters['proposed_action'];
    if (proposed != null) {
      if (proposed is! Map) {
        throw const ConversationActionValidationException(
          'Proposed action must be an object.',
        );
      }
      final nested = ConversationAction.fromJson(
        Map<String, dynamic>.from(proposed),
      );
      if (nested.type == ConversationActionType.requestConfirmation ||
          nested.type == ConversationActionType.requestClarification) {
        throw const ConversationActionValidationException(
          'Nested conversation controls are not supported.',
        );
      }
    }
    if (type == ConversationActionType.queryReminders) {
      final scope = parameters['scope']?.toString();
      if (!const {
        'today',
        'tomorrow',
        'upcoming',
        'overdue',
        'date',
      }.contains(scope)) {
        throw const ConversationActionValidationException(
          'Unsupported reminder query.',
        );
      }
      final queryDate = parameters['date']?.toString();
      if ((scope == 'date' && (queryDate == null || !_validDate(queryDate))) ||
          (scope != 'date' && queryDate != null)) {
        throw const ConversationActionValidationException(
          'Invalid reminder query date.',
        );
      }
    }
    final changes = parameters['changes'];
    if (changes != null && changes is! Map) {
      throw const ConversationActionValidationException(
        'Changes must be an object.',
      );
    }
    if (type == ConversationActionType.requestConfirmation) {
      final proposed = parameters['proposed_action'];
      if (proposed is! Map) {
        throw const ConversationActionValidationException(
          'Confirmation requires a proposed action.',
        );
      }
      final nested = ConversationAction.fromJson(
        Map<String, dynamic>.from(proposed),
      );
      if (nested.type == ConversationActionType.requestConfirmation) {
        throw const ConversationActionValidationException(
          'Nested confirmations are not supported.',
        );
      }
    }
    if (type == ConversationActionType.requestClarification &&
        parameters['choice_actions'] != null) {
      final choices = parameters['choice_actions'];
      if (choices is! List || choices.length > 3) {
        throw const ConversationActionValidationException(
          'Invalid clarification choices.',
        );
      }
      for (final choice in choices) {
        if (choice is! Map) {
          throw const ConversationActionValidationException(
            'Invalid clarification choice.',
          );
        }
        ConversationAction.fromJson(Map<String, dynamic>.from(choice));
      }
    }
  }

  static final _actionId = RegExp(r'^[A-Za-z0-9:_-]{8,100}$');
  static final _uuid = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
    caseSensitive: false,
  );
  static final _date = RegExp(r'^\d{4}-\d{2}-\d{2}$');
  static final _time = RegExp(r'^(?:[01]\d|2[0-3]):[0-5]\d(?::[0-5]\d)?$');

  static bool _validDate(String value) {
    if (!_date.hasMatch(value)) return false;
    final parts = value.split('-').map(int.parse).toList();
    final parsed = DateTime.utc(parts[0], parts[1], parts[2]);
    return parsed.year == parts[0] &&
        parsed.month == parts[1] &&
        parsed.day == parts[2];
  }
}

const _allowedParameters = <ConversationActionType, Set<String>>{
  ConversationActionType.recordRentalExpense: {
    'attachment_id',
    'document_id',
    'property_id',
    'property_name',
    'create_property',
    'address',
    'amount',
    'currency',
    'expected_updated_at',
    'property_version',
  },
  ConversationActionType.searchFamilyContent: {'query', 'document_id'},
  ConversationActionType.queryReminders: {'scope', 'date'},
  ConversationActionType.saveDocument: {
    'attachment_id',
    'category_name',
    'tags',
    'create_category',
  },
  ConversationActionType.requestDocumentOcr: {
    'attachment_id',
    'document_id',
    'mode',
  },
  ConversationActionType.updateDocumentCategory: {
    'document_id',
    'category_name',
    'expected_updated_at',
    'ambiguous',
  },
  ConversationActionType.updateDocumentTags: {
    'document_id',
    'tags',
    'operation',
    'expected_updated_at',
  },
  ConversationActionType.createReminder: {
    'title',
    'due_date',
    'due_time',
    'document_id',
  },
  ConversationActionType.updateReminder: {
    'reminder_id',
    'operation',
    'expected_due_date',
    'due_date',
    'due_time',
    'recurrence',
  },
  ConversationActionType.saveLink: {
    'url',
    'title',
    'category_name',
    'create_category',
  },
  ConversationActionType.markInboxReviewed: {'inbox_id', 'expected_updated_at'},
  ConversationActionType.dismissInboxItem: {'inbox_id', 'expected_updated_at'},
  ConversationActionType.openAppDestination: {'destination', 'result_index'},
  ConversationActionType.requestClarification: {
    'question',
    'missing_parameter',
    'proposed_action',
    'choices',
    'choice_actions',
    'link_url',
    'link_title',
    'attachment_id',
    'tags',
    'draft_title',
    'draft_date',
    'draft_time',
  },
  ConversationActionType.requestConfirmation: {
    'summary',
    'proposed_action',
    'target_label',
    'changes',
  },
  ConversationActionType.unsupportedRequest: {'reason'},
};

const _requiredParameters = <ConversationActionType, Set<String>>{
  ConversationActionType.searchFamilyContent: {'query'},
  ConversationActionType.queryReminders: {'scope'},
  ConversationActionType.saveDocument: {'attachment_id', 'category_name'},
  ConversationActionType.requestDocumentOcr: {'mode'},
  ConversationActionType.updateDocumentCategory: {
    'document_id',
    'category_name',
  },
  ConversationActionType.updateDocumentTags: {
    'document_id',
    'tags',
    'operation',
  },
  ConversationActionType.createReminder: {'title', 'due_date'},
  ConversationActionType.updateReminder: {
    'reminder_id',
    'operation',
    'expected_due_date',
  },
  ConversationActionType.saveLink: {'url', 'category_name'},
  ConversationActionType.markInboxReviewed: {'inbox_id'},
  ConversationActionType.dismissInboxItem: {'inbox_id'},
  ConversationActionType.openAppDestination: {'destination'},
  ConversationActionType.requestClarification: {
    'question',
    'missing_parameter',
  },
  ConversationActionType.requestConfirmation: {'summary', 'proposed_action'},
};

void _expectKeys(Map<dynamic, dynamic> value, Set<String> allowed) {
  for (final key in value.keys) {
    if (key is! String || !allowed.contains(key)) {
      throw ConversationActionValidationException('Unknown property: $key.');
    }
  }
}

class ConversationReference {
  const ConversationReference({
    required this.type,
    required this.id,
    required this.label,
    this.metadata = const {},
  });

  factory ConversationReference.fromJson(Map<String, dynamic> json) =>
      ConversationReference(
        type: json['type']?.toString() ?? '',
        id: json['id']?.toString() ?? '',
        label: json['label']?.toString() ?? '',
        metadata: Map<String, dynamic>.from(
          json['metadata'] as Map? ?? const {},
        ),
      );

  final String type;
  final String id;
  final String label;
  final Map<String, dynamic> metadata;

  Map<String, dynamic> toJson() => {
    'type': type,
    'id': id,
    'label': label,
    'metadata': metadata,
  };
}

class ConversationSuggestion {
  const ConversationSuggestion({required this.label, required this.action});

  factory ConversationSuggestion.fromJson(Map<String, dynamic> json) =>
      ConversationSuggestion(
        label: json['label']?.toString() ?? '',
        action: ConversationAction.fromJson(
          Map<String, dynamic>.from(json['action'] as Map),
        ),
      );

  final String label;
  final ConversationAction action;

  Map<String, dynamic> toJson() => {'label': label, 'action': action.toJson()};
}

class ConversationClarificationOption {
  const ConversationClarificationOption({
    required this.id,
    required this.label,
    this.description,
  });

  final String id;
  final String label;
  final String? description;
}

class ConversationMessage {
  const ConversationMessage({
    required this.id,
    required this.role,
    required this.kind,
    required this.content,
    required this.createdAt,
    this.data = const {},
    this.suggestions = const [],
  });

  factory ConversationMessage.fromJson(Map<String, dynamic> json) {
    final data = Map<String, dynamic>.from(json['data'] as Map? ?? const {});
    return ConversationMessage(
      id: (json['client_message_id'] ?? json['id']).toString(),
      role: json['role'] == 'user'
          ? ConversationRole.user
          : ConversationRole.assistant,
      kind: ConversationMessageKind.values.firstWhere(
        (kind) => kind.name == json['kind'],
        orElse: () => ConversationMessageKind.text,
      ),
      content: json['content']?.toString() ?? '',
      createdAt:
          DateTime.tryParse(json['created_at']?.toString() ?? '')?.toLocal() ??
          DateTime.now(),
      data: data,
      suggestions: (data['suggestions'] as List? ?? const [])
          .whereType<Map>()
          .map((value) {
            try {
              return ConversationSuggestion.fromJson(
                Map<String, dynamic>.from(value),
              );
            } on ConversationActionValidationException {
              return null;
            }
          })
          .whereType<ConversationSuggestion>()
          .take(3)
          .toList(),
    );
  }

  final String id;
  final ConversationRole role;
  final ConversationMessageKind kind;
  final String content;
  final DateTime createdAt;
  final Map<String, dynamic> data;
  final List<ConversationSuggestion> suggestions;

  List<ConversationClarificationOption> get clarificationOptions {
    final labels = (data['choices'] as List? ?? const [])
        .map((value) => value.toString())
        .toList();
    final actions = data['choice_actions'] as List? ?? const [];
    final options = <ConversationClarificationOption>[];
    for (
      var index = 0;
      index < labels.length && index < actions.length;
      index++
    ) {
      final raw = actions[index];
      if (raw is! Map) continue;
      final id = raw['id']?.toString() ?? '';
      if (!_clarificationOptionId.hasMatch(id) ||
          labels[index].trim().isEmpty) {
        continue;
      }
      options.add(
        ConversationClarificationOption(id: id, label: labels[index].trim()),
      );
    }
    return options;
  }

  String? get clarificationId => data['clarification_id']?.toString();

  bool get offersMoreCategories {
    final action = data['action'];
    if (action is! Map) return false;
    final parameters = action['parameters'];
    return parameters is Map &&
        const {
          'document_category',
          'category_name',
        }.contains(parameters['missing_parameter']) &&
        parameters['attachment_id'] != null;
  }

  Map<String, dynamic> toData() => {
    ...data,
    if (suggestions.isNotEmpty)
      'suggestions': suggestions.map((item) => item.toJson()).toList(),
  };
}

final _clarificationOptionId = RegExp(r'^[A-Za-z0-9:_-]{8,100}$');

class ConversationConfirmation {
  ConversationConfirmation({
    String? id,
    this.action,
    required this.summary,
    required this.targetLabel,
    required this.expiresAt,
  }) : id =
           id ??
           action?.id ??
           (throw const ConversationActionValidationException(
             'Confirmation identifier is required.',
           ));

  final String id;
  @Deprecated('Executable confirmation actions are not used in production.')
  final ConversationAction? action;
  final String summary;
  final String targetLabel;
  final DateTime expiresAt;
  bool get expired => !expiresAt.isAfter(DateTime.now());
}

class ConversationAuthoritativeOutcome {
  const ConversationAuthoritativeOutcome({
    required this.executionId,
    required this.state,
    required this.actionType,
    required this.result,
    this.errorCategory,
    this.confirmation,
  });

  final String executionId;
  final String state;
  final String actionType;
  final Map<String, dynamic> result;
  final String? errorCategory;
  final ConversationConfirmation? confirmation;

  String get message =>
      result['message']?.toString() ?? 'That action could not be completed.';
}

class ConversationExecutionResult {
  const ConversationExecutionResult({
    required this.message,
    this.data = const {},
    this.references = const [],
    this.suggestions = const [],
  });
  final String message;
  final Map<String, dynamic> data;
  final List<ConversationReference> references;
  final List<ConversationSuggestion> suggestions;
}
