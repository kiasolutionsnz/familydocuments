import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../../core/auth/auth_service.dart';
import '../models/conversation_models.dart';

class ConversationServiceException implements Exception {
  const ConversationServiceException(this.message, {this.expired = false});
  final String message;
  final bool expired;
}

class ConversationSnapshot {
  const ConversationSnapshot({
    this.id,
    this.messages = const [],
    this.pendingConfirmation,
  });
  final String? id;
  final List<ConversationMessage> messages;
  final ConversationConfirmation? pendingConfirmation;
}

class ActiveFamilyChoice {
  const ActiveFamilyChoice({
    required this.id,
    required this.name,
    required this.role,
    this.selected = false,
  });
  final String id;
  final String name;
  final String role;
  final bool selected;
}

class ActiveFamilyWorkspace {
  const ActiveFamilyWorkspace({
    required this.selectionRequired,
    required this.families,
  });
  final bool selectionRequired;
  final List<ActiveFamilyChoice> families;
}

class ConversationCategoryOption {
  const ConversationCategoryOption({required this.id, required this.name});
  final String id;
  final String name;
}

class ConversationCategoryOptions {
  const ConversationCategoryOptions({
    required this.categories,
    required this.canSave,
    required this.canCreate,
  });
  final List<ConversationCategoryOption> categories;
  final bool canSave;
  final bool canCreate;
}

abstract class ConversationRepository {
  Future<ConversationSnapshot> restore([String? conversationId]);
  Future<String> start(String requestId);
  Future<void> append(String conversationId, ConversationMessage message);
  Future<ConversationAction> interpret({
    required String message,
    required List<ConversationReference> references,
    required bool hasAttachment,
    String? attachmentId,
  });
  Future<ConversationAuthoritativeOutcome> submitAction(
    String conversationId,
    ConversationAction action,
    String requestKey,
  );
  Future<ConversationAuthoritativeOutcome> decideConfirmation(
    String confirmationId, {
    required bool confirm,
  });
  Future<ConversationAuthoritativeOutcome> decideClarification(
    String clarificationId, {
    required String decision,
    String? optionId,
  });
  Future<String> stageAttachment({
    required String conversationId,
    required String fileName,
    required String mimeType,
    required List<int> bytes,
  });
  Future<Map<String, dynamic>> recordJobTransition(
    String conversationId,
    String jobId,
  );
  Future<void> delete(String conversationId);
  Future<ActiveFamilyWorkspace> activeFamilyWorkspace();
  Future<void> selectActiveFamily(String familyId);
  Future<ConversationCategoryOptions> categoryOptions({
    required String conversationId,
    required String attachmentId,
    required String fileName,
  });
}

/// Used only by injected widget/fake-service harnesses. Production constructs
/// [ConversationService] and persists through the authenticated backend.
class MemoryConversationRepository implements ConversationRepository {
  final List<ConversationMessage> messages = [];
  String? id;
  ConversationConfirmation? pending;
  Future<ConversationAuthoritativeOutcome> Function(ConversationAction action)?
  actionHandler;

  @override
  Future<void> append(
    String conversationId,
    ConversationMessage message,
  ) async {
    messages.add(message);
  }

  @override
  Future<ConversationAction> interpret({
    required String message,
    required List<ConversationReference> references,
    required bool hasAttachment,
    String? attachmentId,
  }) async => throw const ConversationServiceException(
    'Model interpretation is unavailable in this test harness.',
  );

  @override
  Future<ConversationSnapshot> restore([String? conversationId]) async =>
      ConversationSnapshot(
        id: id,
        messages: List.of(messages),
        pendingConfirmation: pending,
      );

  @override
  Future<ConversationAuthoritativeOutcome> submitAction(
    String conversationId,
    ConversationAction action,
    String requestKey,
  ) async {
    final needsConfirmation =
        action.type == ConversationActionType.recordRentalExpense ||
        action.type == ConversationActionType.saveLink ||
        action.type == ConversationActionType.dismissInboxItem ||
        action.type == ConversationActionType.updateReminder ||
        (action.type == ConversationActionType.updateDocumentTags &&
            action.parameters['operation'] == 'remove') ||
        (action.type == ConversationActionType.updateDocumentCategory &&
            action.parameters['ambiguous'] == true) ||
        ((action.type == ConversationActionType.saveDocument ||
                action.type == ConversationActionType.saveLink) &&
            action.parameters['create_category'] == true);
    if (needsConfirmation) {
      final category = action.parameters['category_name']?.toString();
      final linkHost = action.type == ConversationActionType.saveLink
          ? Uri.tryParse(action.parameters['url']?.toString() ?? '')?.host
          : null;
      pending = ConversationConfirmation(
        id: '55555555-5555-4555-8555-555555555555',
        action: action,
        summary: linkHost != null && linkHost.isNotEmpty
            ? 'Save this link to $linkHost?'
            : action.parameters['create_category'] == true && category != null
            ? 'Create $category and save this item?'
            : 'Confirm this change?',
        targetLabel: linkHost ?? 'Selected item',
        expiresAt: DateTime.now().add(const Duration(minutes: 10)),
      );
      messages.add(
        ConversationMessage(
          id: 'confirmation-${messages.length + 100}',
          role: ConversationRole.assistant,
          kind: ConversationMessageKind.confirmation,
          content: pending!.summary,
          createdAt: DateTime.now(),
        ),
      );
      return ConversationAuthoritativeOutcome(
        executionId: action.id,
        state: 'awaiting_confirmation',
        actionType: action.type.wireName,
        result: const {},
        confirmation: pending,
      );
    }
    final outcome =
        (action.type == ConversationActionType.requestClarification
            ? null
            : await actionHandler?.call(action)) ??
        ConversationAuthoritativeOutcome(
          executionId: action.id,
          state: action.type == ConversationActionType.requestClarification
              ? 'awaiting_clarification'
              : 'succeeded',
          actionType: action.type.wireName,
          result: {
            'message': action.type == ConversationActionType.unsupportedRequest
                ? 'I can help organise and find information in your FamilyDocuments account.'
                : action.parameters['question'] ?? 'Completed.',
          },
        );
    messages.add(
      ConversationMessage(
        id: 'outcome-${messages.length + 100}',
        role: ConversationRole.assistant,
        kind: action.type == ConversationActionType.requestClarification
            ? ConversationMessageKind.clarification
            : outcome.state.startsWith('failed')
            ? ConversationMessageKind.error
            : ConversationMessageKind.result,
        content: outcome.message,
        createdAt: DateTime.now(),
        data: action.type == ConversationActionType.requestClarification
            ? {
                'clarification_id': action.id,
                'action': action.toJson(),
                'choices': action.parameters['choices'] ?? const <String>[],
                'choice_actions':
                    action.parameters['choice_actions'] ?? const <Object>[],
              }
            : outcome.result,
        suggestions: action.type == ConversationActionType.requestClarification
            ? const []
            : _memorySuggestions(action, outcome.result),
      ),
    );
    return outcome;
  }

  List<ConversationSuggestion> _memorySuggestions(
    ConversationAction action,
    Map<String, dynamic> result,
  ) {
    final explicit = result['suggestions'];
    if (explicit is List) {
      return explicit
          .whereType<Map>()
          .map(
            (value) => ConversationSuggestion.fromJson(
              Map<String, dynamic>.from(value),
            ),
          )
          .take(3)
          .toList();
    }
    final choices = action.parameters['choices'];
    final choiceActions = action.parameters['choice_actions'];
    if (choices is! List || choiceActions is! List) return const [];
    final suggestions = <ConversationSuggestion>[];
    for (
      var index = 0;
      index < choices.length && index < choiceActions.length && index < 3;
      index++
    ) {
      if (choiceActions[index] is Map) {
        suggestions.add(
          ConversationSuggestion(
            label: choices[index].toString(),
            action: ConversationAction.fromJson(
              Map<String, dynamic>.from(choiceActions[index] as Map),
            ),
          ),
        );
      }
    }
    return suggestions;
  }

  @override
  Future<ConversationAuthoritativeOutcome> decideClarification(
    String clarificationId, {
    required String decision,
    String? optionId,
  }) async {
    final clarification = messages.lastWhere(
      (message) => message.clarificationId == clarificationId,
    );
    if (decision == 'redisplay') {
      messages.add(
        ConversationMessage(
          id: 'redisplay-${messages.length + 100}',
          role: ConversationRole.assistant,
          kind: ConversationMessageKind.clarification,
          content: clarification.content,
          createdAt: DateTime.now(),
          data: clarification.data,
        ),
      );
      return ConversationAuthoritativeOutcome(
        executionId: clarificationId,
        state: 'awaiting_clarification',
        actionType: 'request_clarification',
        result: {'message': clarification.content},
      );
    }
    if (decision == 'select') {
      final action = (clarification.data['choice_actions'] as List? ?? const [])
          .whereType<Map>()
          .map((value) => Map<String, dynamic>.from(value))
          .where((value) => value['id'] == optionId)
          .map(ConversationAction.fromJson)
          .first;
      return submitAction(
        id!,
        action,
        'clarification-$clarificationId-$optionId',
      );
    }
    final message = decision == 'cancel'
        ? 'Okay, cancelled.'
        : 'Superseded by your new request.';
    if (decision == 'cancel') {
      messages.add(
        ConversationMessage(
          id: 'cancel-${messages.length + 100}',
          role: ConversationRole.assistant,
          kind: ConversationMessageKind.result,
          content: message,
          createdAt: DateTime.now(),
        ),
      );
    }
    return ConversationAuthoritativeOutcome(
      executionId: clarificationId,
      state: 'cancelled',
      actionType: 'request_clarification',
      result: {'message': message},
    );
  }

  @override
  Future<ConversationAuthoritativeOutcome> decideConfirmation(
    String confirmationId, {
    required bool confirm,
  }) async {
    if (pending == null || pending!.id != confirmationId || pending!.expired) {
      throw const ConversationServiceException(
        'That confirmation has expired. Please ask again.',
        expired: true,
      );
    }
    final action = pending!.action;
    pending = null;
    final outcome = confirm && action != null && actionHandler != null
        ? await actionHandler!(action)
        : ConversationAuthoritativeOutcome(
            executionId: confirmationId,
            state: confirm ? 'succeeded' : 'cancelled',
            actionType: 'test',
            result: {
              'message': confirm
                  ? 'Completed.'
                  : 'Okay, I didn’t make that change.',
            },
          );
    messages.add(
      ConversationMessage(
        id: 'decision-${messages.length + 100}',
        role: ConversationRole.assistant,
        kind: ConversationMessageKind.result,
        content: outcome.message,
        createdAt: DateTime.now(),
        data: outcome.result,
        suggestions: action == null
            ? const []
            : _memorySuggestions(action, outcome.result),
      ),
    );
    return outcome;
  }

  @override
  Future<String> stageAttachment({
    required String conversationId,
    required String fileName,
    required String mimeType,
    required List<int> bytes,
  }) async => 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaab';

  @override
  Future<Map<String, dynamic>> recordJobTransition(
    String conversationId,
    String jobId,
  ) async => const {'changed': false};

  void recordSyntheticJobTransition({
    required String correlationId,
    required String text,
    required String status,
    required Map<String, dynamic> data,
    required List<ConversationSuggestion> suggestions,
  }) {
    messages.removeWhere(
      (message) => message.data['correlation_id'] == correlationId,
    );
    messages.add(
      ConversationMessage(
        id: 'synthetic-transition-${messages.length + 100}',
        role: ConversationRole.assistant,
        kind: status == 'finished'
            ? ConversationMessageKind.result
            : status == 'failed'
            ? ConversationMessageKind.error
            : ConversationMessageKind.progress,
        content: text,
        createdAt: DateTime.now(),
        data: {'correlation_id': correlationId, 'status': status, ...data},
        suggestions: suggestions,
      ),
    );
  }

  @override
  Future<void> delete(String conversationId) async {
    messages.clear();
    pending = null;
  }

  @override
  Future<ActiveFamilyWorkspace> activeFamilyWorkspace() async =>
      const ActiveFamilyWorkspace(selectionRequired: false, families: []);

  @override
  Future<void> selectActiveFamily(String familyId) async {}

  @override
  Future<ConversationCategoryOptions> categoryOptions({
    required String conversationId,
    required String attachmentId,
    required String fileName,
  }) async => const ConversationCategoryOptions(
    categories: [
      ConversationCategoryOption(id: 'category-finance', name: 'Finance'),
      ConversationCategoryOption(id: 'category-rentals', name: 'Rentals'),
      ConversationCategoryOption(id: 'category-travel', name: 'Travel'),
    ],
    canSave: true,
    canCreate: true,
  );

  @override
  Future<String> start(String requestId) async {
    id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
    messages.clear();
    pending = null;
    return id!;
  }
}

class ConversationService implements ConversationRepository {
  ConversationService(this._auth, {http.Client? client})
    : _client = client ?? http.Client();

  final AuthService _auth;
  final http.Client _client;
  final Map<String, String> _proposalTokens = {};

  Future<http.Response> _post(String path, Map<String, dynamic> body) async {
    Future<http.Response> send() async => _client.post(
      Uri.parse('$familyDocumentsApiBaseUrl$path'),
      headers: {
        'authorization': 'Bearer ${await _auth.validAccessToken()}',
        'content-type': 'application/json',
      },
      body: jsonEncode(body),
    );
    try {
      var response = await send();
      if (response.statusCode == 401) {
        await _auth.refresh();
        response = await send();
      }
      return response;
    } on AuthException {
      rethrow;
    } catch (_) {
      throw const ConversationServiceException(
        'The conversation could not be reached. Try again.',
      );
    }
  }

  @override
  Future<ConversationSnapshot> restore([String? conversationId]) async {
    final response = await _post('/rest/rpc/conversation_workspace', {
      'conversation': conversationId,
    });
    if (response.statusCode != 200) {
      throw const ConversationServiceException(
        'Your conversation could not be restored. Try again.',
      );
    }
    try {
      final payload = Map<String, dynamic>.from(
        jsonDecode(response.body) as Map,
      );
      final rawConversation = payload['conversation'];
      if (rawConversation is! Map) return const ConversationSnapshot();
      final messages = (payload['messages'] as List? ?? const [])
          .whereType<Map>()
          .map(
            (value) =>
                ConversationMessage.fromJson(Map<String, dynamic>.from(value)),
          )
          .toList();
      ConversationConfirmation? confirmation;
      final rawConfirmation = payload['pending_confirmation'];
      if (rawConfirmation is Map) {
        final value = Map<String, dynamic>.from(rawConfirmation);
        confirmation = ConversationConfirmation(
          id: value['id']?.toString() ?? '',
          summary: value['summary']?.toString() ?? 'Confirm this change?',
          targetLabel: value['target_label']?.toString() ?? 'Item',
          expiresAt:
              DateTime.tryParse(value['expires_at']?.toString() ?? '')
                  ?.toLocal() ??
              DateTime.now(),
        );
      }
      return ConversationSnapshot(
        id: rawConversation['id']?.toString(),
        messages: messages,
        pendingConfirmation: confirmation?.expired == true
            ? null
            : confirmation,
      );
    } catch (_) {
      throw const ConversationServiceException(
        'Your conversation returned an unexpected response.',
      );
    }
  }

  @override
  Future<String> start(String requestId) async {
    final response = await _post('/rest/rpc/start_conversation', {
      'request_id': requestId,
    });
    if (response.statusCode != 200) {
      throw const ConversationServiceException(
        'A new conversation could not be started. Try again.',
      );
    }
    final payload = Map<String, dynamic>.from(jsonDecode(response.body) as Map);
    final id = payload['id']?.toString() ?? '';
    if (id.isEmpty) {
      throw const ConversationServiceException(
        'A new conversation could not be started. Try again.',
      );
    }
    return id;
  }

  @override
  Future<void> append(
    String conversationId,
    ConversationMessage message,
  ) async {
    final response = await _post('/rest/rpc/append_conversation_message', {
      'conversation': conversationId,
      'client_message_id': message.id,
      'message_role': message.role.name,
      'message_kind': message.kind.name,
      'message_content': message.content,
      'message_data': message.toData(),
    });
    if (response.statusCode != 200) {
      throw const ConversationServiceException(
        'That message could not be saved. Try again.',
      );
    }
  }

  @override
  Future<ConversationAction> interpret({
    required String message,
    required List<ConversationReference> references,
    required bool hasAttachment,
    String? attachmentId,
  }) async {
    final response = await _post('/conversation/interpret', {
      'message': message,
      'context': {
        'has_attachment': hasAttachment,
        'attachment_id': ?attachmentId,
        'references': references
            .take(8)
            .map(
              (reference) => {
                'type': reference.type,
                'id': reference.id,
                'label': reference.label,
              },
            )
            .toList(),
      },
    });
    if (response.statusCode != 200) {
      throw const ConversationServiceException(
        'I need a little more detail to do that safely.',
      );
    }
    try {
      final payload = Map<String, dynamic>.from(
        jsonDecode(response.body) as Map,
      );
      final action = ConversationAction.fromJson(
        Map<String, dynamic>.from(payload['action'] as Map),
      );
      final token = payload['proposal_token']?.toString();
      if (token != null && token.isNotEmpty) _proposalTokens[action.id] = token;
      return action;
    } on ConversationActionValidationException {
      throw const ConversationServiceException(
        'I need a little more detail to do that safely.',
      );
    } catch (_) {
      throw const ConversationServiceException(
        'I need a little more detail to do that safely.',
      );
    }
  }

  @override
  Future<ConversationAuthoritativeOutcome> submitAction(
    String conversationId,
    ConversationAction action,
    String requestKey,
  ) async {
    final proposalToken = _proposalTokens[action.id];
    final response = await _post('/conversation/action', {
      'conversation_id': conversationId,
      'request_key': requestKey,
      'action': action.toJson(),
      'proposal_token': ?proposalToken,
    });
    final fallback = action.type == ConversationActionType.createReminder
        ? 'The reminder could not be saved. Check the date and try again.'
        : 'That action could not be completed. Try again.';
    final outcome = _outcome(response, fallback);
    if (response.statusCode >= 200 && response.statusCode < 300) {
      _proposalTokens.remove(action.id);
    }
    return outcome;
  }

  @override
  Future<ConversationAuthoritativeOutcome> decideClarification(
    String clarificationId, {
    required String decision,
    String? optionId,
  }) async {
    final response = await _post('/conversation/clarification', {
      'clarification_id': clarificationId,
      'decision': decision,
      'option_id': ?optionId,
    });
    return _outcome(response, 'That choice could not be completed.');
  }

  @override
  Future<ConversationAuthoritativeOutcome> decideConfirmation(
    String confirmationId, {
    required bool confirm,
  }) async {
    final response = await _post('/conversation/decision', {
      'confirmation_id': confirmationId,
      'decision': confirm ? 'confirm' : 'cancel',
    });
    return _outcome(response, 'That confirmation could not be completed.');
  }

  @override
  Future<String> stageAttachment({
    required String conversationId,
    required String fileName,
    required String mimeType,
    required List<int> bytes,
  }) async {
    final response = await _post('/conversation/attachment', {
      'conversation_id': conversationId,
      'file_name': fileName,
      'mime_type': mimeType,
      'content_base64': base64Encode(bytes),
    });
    if (response.statusCode != 200) {
      throw ConversationServiceException(
        _safeFailureMessage(
          response,
          'The file could not be prepared. Try again.',
        ),
      );
    }
    final payload = Map<String, dynamic>.from(jsonDecode(response.body) as Map);
    return payload['id']?.toString() ??
        (throw const ConversationServiceException(
          'The file could not be prepared. Try again.',
        ));
  }

  @override
  Future<Map<String, dynamic>> recordJobTransition(
    String conversationId,
    String jobId,
  ) async {
    final response = await _post(
      '/rest/rpc/record_conversation_job_transition',
      {'conversation': conversationId, 'job': jobId},
    );
    if (response.statusCode != 200) {
      throw const ConversationServiceException(
        'Document progress is temporarily unavailable.',
      );
    }
    return Map<String, dynamic>.from(jsonDecode(response.body) as Map);
  }

  @override
  Future<void> delete(String conversationId) async {
    final response = await _post('/rest/rpc/delete_conversation', {
      'conversation': conversationId,
    });
    if (response.statusCode != 200) {
      throw const ConversationServiceException(
        'The conversation could not be deleted.',
      );
    }
  }

  @override
  Future<ActiveFamilyWorkspace> activeFamilyWorkspace() async {
    final response = await _post('/rest/rpc/active_family_workspace', const {});
    if (response.statusCode != 200) {
      throw const ConversationServiceException(
        'Your Family access could not be checked.',
      );
    }
    final payload = Map<String, dynamic>.from(jsonDecode(response.body) as Map);
    final families = (payload['families'] as List? ?? const [])
        .whereType<Map>()
        .map(
          (value) => ActiveFamilyChoice(
            id: value['id']?.toString() ?? '',
            name: value['name']?.toString() ?? 'Family',
            role: value['role']?.toString() ?? '',
            selected: value['selected'] == true,
          ),
        )
        .toList();
    return ActiveFamilyWorkspace(
      selectionRequired: payload['selection_required'] == true,
      families: families,
    );
  }

  @override
  Future<void> selectActiveFamily(String familyId) async {
    final response = await _post('/rest/rpc/select_active_family', {
      'family': familyId,
    });
    if (response.statusCode != 200) {
      throw const ConversationServiceException(
        'That Family is no longer available.',
      );
    }
  }

  @override
  Future<ConversationCategoryOptions> categoryOptions({
    required String conversationId,
    required String attachmentId,
    required String fileName,
  }) async {
    final response = await _post('/conversation/categories', {
      'conversation_id': conversationId,
      'attachment_id': attachmentId,
      'file_name': fileName,
    });
    if (response.statusCode != 200) {
      throw const ConversationServiceException(
        'Categories could not be loaded. Try again.',
      );
    }
    try {
      final payload = Map<String, dynamic>.from(
        jsonDecode(response.body) as Map,
      );
      final categories = (payload['categories'] as List? ?? const [])
          .whereType<Map>()
          .map(
            (value) => ConversationCategoryOption(
              id: value['id']?.toString() ?? '',
              name: value['name']?.toString() ?? '',
            ),
          )
          .where((value) => value.id.isNotEmpty && value.name.isNotEmpty)
          .toList();
      return ConversationCategoryOptions(
        categories: categories,
        canSave: payload['can_save'] == true,
        canCreate: payload['can_create'] == true,
      );
    } catch (_) {
      throw const ConversationServiceException(
        'Categories returned an unexpected response.',
      );
    }
  }

  ConversationAuthoritativeOutcome _outcome(
    http.Response response,
    String fallback,
  ) {
    if (response.statusCode != 200) {
      throw ConversationServiceException(
        _safeFailureMessage(response, fallback),
      );
    }
    try {
      final payload = Map<String, dynamic>.from(
        jsonDecode(response.body) as Map,
      );
      final rawConfirmation = payload['confirmation'];
      return ConversationAuthoritativeOutcome(
        executionId: payload['execution_id']?.toString() ?? '',
        state: payload['state']?.toString() ?? 'permanently_failed',
        actionType: payload['action_type']?.toString() ?? '',
        result: Map<String, dynamic>.from(
          payload['result'] as Map? ?? const {},
        ),
        errorCategory: payload['error_category']?.toString(),
        confirmation: rawConfirmation is Map
            ? ConversationConfirmation(
                id: rawConfirmation['id']?.toString() ?? '',
                summary:
                    rawConfirmation['summary']?.toString() ??
                    'Confirm this change?',
                targetLabel:
                    rawConfirmation['target_label']?.toString() ??
                    'Selected item',
                expiresAt:
                    DateTime.tryParse(
                      rawConfirmation['expires_at']?.toString() ?? '',
                    )?.toLocal() ??
                    DateTime.now(),
              )
            : null,
      );
    } catch (_) {
      throw ConversationServiceException(fallback);
    }
  }

  String _safeFailureMessage(http.Response response, String fallback) {
    String? category;
    try {
      final payload = jsonDecode(response.body);
      if (payload is Map) category = payload['error']?.toString();
    } catch (_) {
      // The server body is intentionally not surfaced to the user.
    }
    return switch (category) {
      'authentication_required' =>
        'Your session has expired. Please sign in again.',
      'origin_denied' ||
      'permission_denied' => 'You don’t have permission to do that.',
      'service_unavailable' =>
        'FamilyDocuments is temporarily unavailable. Try again.',
      'drive_not_configured' || 'drive_not_available' =>
        'Connect Google Drive in Settings before attaching a document.',
      'drive_reconnect_required' => 'Google Drive needs to be reconnected in Settings before you can attach a document.',
      'drive_unavailable' ||
      'drive_upload_unconfirmed' ||
      'drive_file_unavailable' => 'Google Drive is temporarily unavailable. Your document was not saved here; please retry.',
      'drive_upload_pending' =>
        'The upload could not be confirmed yet. Retry with the same file.',
      'drive_upload_not_authorised' => 'This document could not be saved in the active Family. Check your access and try again.',
      'invalid_request' || 'action_rejected' => fallback,
      _ =>
        response.statusCode == 401
            ? 'Your session has expired. Please sign in again.'
            : fallback,
    };
  }
}
