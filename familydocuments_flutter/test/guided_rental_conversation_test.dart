import 'package:familydocuments_flutter/features/conversation/conversation_controller.dart';
import 'package:familydocuments_flutter/features/conversation/data/conversation_service.dart';
import 'package:familydocuments_flutter/features/conversation/models/conversation_models.dart';
import 'package:flutter_test/flutter_test.dart';

const attachment = '56000000-0000-4000-8000-000000000001';

// Scripted authoritative responses, not a replacement production executor.
class DraftRepository extends MemoryConversationRepository {
  final proposals = <ConversationAction>[];

  @override
  Future<ConversationAuthoritativeOutcome> submitAction(
    String conversationId,
    ConversationAction action,
    String requestKey,
  ) async {
    proposals.add(action);
    if (action.type == ConversationActionType.recordRentalExpense) {
      final p = action.parameters;
      final missing = p['create_property'] != true
          ? 'rental_property'
          : p['address'] == null
          ? 'rental_address'
          : p['amount'] == null
          ? 'rental_amount'
          : null;
      if (missing != null) {
        action = ConversationAction(
          id: action.id,
          type: ConversationActionType.requestClarification,
          parameters: {
            'question': 'Provide $missing',
            'missing_parameter': missing,
            'proposed_action': action.toJson(),
            'choices': missing == 'rental_property'
                ? ['Create rental']
                : <String>[],
            'choice_actions': missing == 'rental_property'
                ? [
                    ConversationAction(
                      id: 'create-rental-option',
                      type: ConversationActionType.recordRentalExpense,
                      parameters: {...p, 'create_property': true},
                    ).toJson(),
                  ]
                : <Map<String, dynamic>>[],
          },
        );
      }
    }
    return super.submitAction(conversationId, action, requestKey);
  }
}

void main() {
  test(
    'rental draft restores attachment, collects fields, and confirms',
    () async {
      final repository = DraftRepository();
      var subject = ConversationController(repository: repository);
      await subject.submit(
        'add this as rental expense for Kilbirnie',
        hasAttachment: true,
        attachmentId: attachment,
        attachmentLabel: 'Synthetic.pdf',
      );
      expect(
        subject.messages.last.clarificationOptions.single.label,
        'Create rental',
      );
      subject.dispose();
      subject = ConversationController(repository: repository);
      await subject.restore();
      await subject.submit('Create rental');
      expect(repository.proposals.last.parameters['attachment_id'], attachment);
      expect(repository.proposals.last.parameters['create_property'], true);
      await subject.submit('12 Synthetic Street');
      expect(
        repository.proposals.last.parameters['address'],
        '12 Synthetic Street',
      );
      await subject.submit('NZD 125.00');
      expect(repository.proposals.last.parameters['amount'], '125.00');
      expect(
        repository.proposals.last.parameters['property_name'],
        'Kilbirnie',
      );
      expect(subject.confirmation, isNotNull);
      expect(
        repository.proposals.any(
          (p) => p.type == ConversationActionType.requestDocumentOcr,
        ),
        false,
      );
      subject.dispose();
    },
  );

  test(
    'cancel rental draft clears active clarification after refresh',
    () async {
      final repository = DraftRepository();
      final subject = ConversationController(repository: repository);
      await subject.submit(
        'rental expense for Kilbirnie',
        hasAttachment: true,
        attachmentId: attachment,
      );
      await subject.submit('Cancel');
      await subject.restore();
      expect(subject.pendingClarificationId, isNull);
      expect(subject.confirmation, isNull);
      subject.dispose();
    },
  );

  test('invalid amount retains the draft instead of guessing', () async {
    final repository = DraftRepository();
    final subject = ConversationController(repository: repository);
    await subject.submit(
      'rental expense for Kilbirnie',
      hasAttachment: true,
      attachmentId: attachment,
    );
    await subject.submit('Create rental');
    await subject.submit('12 Synthetic Street');
    await subject.submit('whatever you think');
    expect(repository.proposals.last.parameters.containsKey('amount'), false);
    expect(repository.proposals.last.parameters['attachment_id'], attachment);
    expect(subject.confirmation, isNull);
    subject.dispose();
  });
}
