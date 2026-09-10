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

abstract class ConversationRepository {
  Future<ConversationSnapshot> restore([String? conversationId]);
  Future<String> start(String requestId);
  Future<void> append(String conversationId, ConversationMessage message);
  Future<void> saveConfirmation(
    String conversationId,
    ConversationConfirmation confirmation,
  );
  Future<void> consumeConfirmation(
    String conversationId,
    String actionId, {
    required bool cancel,
  });
  Future<void> recordAction(
    String conversationId,
    ConversationAction action, {
    required String status,
    String? targetType,
    String? targetId,
    Map<String, dynamic> result,
  });
  Future<ConversationAction> interpret({
    required String message,
    required List<ConversationReference> references,
    required bool hasAttachment,
  });
}

/// Used only by injected widget/fake-service harnesses. Production constructs
/// [ConversationService] and persists through the authenticated backend.
class MemoryConversationRepository implements ConversationRepository {
  final List<ConversationMessage> messages = [];
  String? id;
  ConversationConfirmation? pending;

  @override
  Future<void> append(
    String conversationId,
    ConversationMessage message,
  ) async {
    messages.add(message);
  }

  @override
  Future<void> consumeConfirmation(
    String conversationId,
    String actionId, {
    required bool cancel,
  }) async {
    if (pending == null || pending!.action.id != actionId || pending!.expired) {
      throw const ConversationServiceException(
        'That confirmation has expired. Please ask again.',
        expired: true,
      );
    }
    pending = null;
  }

  @override
  Future<ConversationAction> interpret({
    required String message,
    required List<ConversationReference> references,
    required bool hasAttachment,
  }) async => throw const ConversationServiceException(
    'Model interpretation is unavailable in this test harness.',
  );

  @override
  Future<void> recordAction(
    String conversationId,
    ConversationAction action, {
    required String status,
    String? targetType,
    String? targetId,
    Map<String, dynamic> result = const {},
  }) async {}

  @override
  Future<ConversationSnapshot> restore([String? conversationId]) async =>
      ConversationSnapshot(
        id: id,
        messages: List.of(messages),
        pendingConfirmation: pending,
      );

  @override
  Future<void> saveConfirmation(
    String conversationId,
    ConversationConfirmation confirmation,
  ) async {
    pending = confirmation;
  }

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
        final action = ConversationAction(
          id: value['action_id']?.toString() ?? '',
          type:
              ConversationActionType.fromWireName(
                value['action_type']?.toString() ?? '',
              ) ??
              ConversationActionType.unsupportedRequest,
          version: (value['version'] as num?)?.toInt() ?? 0,
          parameters: Map<String, dynamic>.from(
            value['parameters'] as Map? ?? const {},
          ),
        );
        confirmation = ConversationConfirmation(
          action: action,
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
  Future<void> saveConfirmation(
    String conversationId,
    ConversationConfirmation confirmation,
  ) async {
    final response = await _post('/rest/rpc/set_conversation_confirmation', {
      'conversation': conversationId,
      'action_id': confirmation.action.id,
      'action_type': confirmation.action.type.wireName,
      'action_version': confirmation.action.version,
      'parameters': confirmation.action.parameters,
      'confirmation_summary': confirmation.summary,
      'confirmation_target': confirmation.targetLabel,
      'expires_at': confirmation.expiresAt.toUtc().toIso8601String(),
    });
    if (response.statusCode != 200) {
      throw const ConversationServiceException(
        'That confirmation could not be prepared. Try again.',
      );
    }
  }

  @override
  Future<void> consumeConfirmation(
    String conversationId,
    String actionId, {
    required bool cancel,
  }) async {
    final response = await _post(
      '/rest/rpc/consume_conversation_confirmation',
      {'conversation': conversationId, 'action_id': actionId, 'cancel': cancel},
    );
    if (response.statusCode == 409 || response.statusCode == 410) {
      throw const ConversationServiceException(
        'That confirmation has expired. Please ask again.',
        expired: true,
      );
    }
    if (response.statusCode != 200) {
      throw const ConversationServiceException(
        'That confirmation could not be completed.',
      );
    }
  }

  @override
  Future<void> recordAction(
    String conversationId,
    ConversationAction action, {
    required String status,
    String? targetType,
    String? targetId,
    Map<String, dynamic> result = const {},
  }) async {
    final response = await _post('/rest/rpc/record_conversation_action', {
      'conversation': conversationId,
      'action_id': action.id,
      'action_type': action.type.wireName,
      'action_status': status,
      'target_type': targetType,
      'target_id': targetId,
      'result_summary': result,
    });
    if (response.statusCode != 200) {
      throw const ConversationServiceException(
        'The action outcome could not be recorded.',
      );
    }
  }

  @override
  Future<ConversationAction> interpret({
    required String message,
    required List<ConversationReference> references,
    required bool hasAttachment,
  }) async {
    final response = await _post('/conversation/interpret', {
      'message': message,
      'context': {
        'has_attachment': hasAttachment,
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
      return ConversationAction.fromJson(
        Map<String, dynamic>.from(payload['action'] as Map),
      );
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
}
