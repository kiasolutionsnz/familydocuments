import 'package:familydocuments_flutter/features/conversation/models/conversation_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('unknown action is rejected', () {
    expect(
      () => ConversationAction.fromJson(const {
        'id': 'action-12345678',
        'type': 'run_sql',
        'version': 1,
        'parameters': <String, dynamic>{},
      }),
      throwsA(isA<ConversationActionValidationException>()),
    );
  });

  test('unknown property is rejected', () {
    expect(
      () => ConversationAction.fromJson(const {
        'id': 'action-12345678',
        'type': 'search_family_content',
        'version': 1,
        'parameters': {'query': 'passport', 'sql': 'select *'},
      }),
      throwsA(isA<ConversationActionValidationException>()),
    );
  });

  test('missing required parameter is rejected', () {
    expect(
      () => ConversationAction(
        id: 'action-12345678',
        type: ConversationActionType.saveLink,
        parameters: const {'url': 'https://example.com'},
      ),
      throwsA(isA<ConversationActionValidationException>()),
    );
  });

  test('malformed identifier and unsafe URL are rejected', () {
    expect(
      () => ConversationAction(
        id: 'action-12345678',
        type: ConversationActionType.updateDocumentCategory,
        parameters: const {
          'document_id': '../other-family',
          'category_name': 'Finance',
        },
      ),
      throwsA(isA<ConversationActionValidationException>()),
    );
    expect(
      () => ConversationAction(
        id: 'action-12345678',
        type: ConversationActionType.saveLink,
        parameters: const {
          'url': 'javascript:alert(1)',
          'category_name': 'Travel',
          'request_id': 'request-12345678',
        },
      ),
      throwsA(isA<ConversationActionValidationException>()),
    );
  });

  test('unsupported operation and invalid date are rejected', () {
    expect(
      () => ConversationAction(
        id: 'action-12345678',
        type: ConversationActionType.updateDocumentTags,
        parameters: const {
          'document_id': '11111111-1111-4111-8111-111111111111',
          'operation': 'replace_all',
          'tags': ['insurance'],
        },
      ),
      throwsA(isA<ConversationActionValidationException>()),
    );
    expect(
      () => ConversationAction(
        id: 'action-12345678',
        type: ConversationActionType.createReminder,
        parameters: const {
          'title': 'Doctor',
          'due_date': 'tomorrow',
          'request_id': 'request-12345678',
        },
      ),
      throwsA(isA<ConversationActionValidationException>()),
    );
    expect(
      () => ConversationAction(
        id: 'action-12345678',
        type: ConversationActionType.createReminder,
        parameters: const {
          'title': 'Doctor',
          'due_date': '2027-02-30',
          'request_id': 'request-12345678',
        },
      ),
      throwsA(isA<ConversationActionValidationException>()),
    );
  });
}
