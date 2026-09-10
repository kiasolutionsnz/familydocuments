import 'package:familydocuments_flutter/features/conversation/models/conversation_models.dart';
import 'package:familydocuments_flutter/features/conversation/widgets/conversation_transcript.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

ConversationMessage message(
  String id,
  ConversationRole role,
  ConversationMessageKind kind,
  String content, {
  Map<String, dynamic> data = const {},
  List<ConversationSuggestion> suggestions = const [],
}) => ConversationMessage(
  id: id,
  role: role,
  kind: kind,
  content: content,
  createdAt: DateTime.utc(2027),
  data: data,
  suggestions: suggestions,
);

void main() {
  testWidgets(
    'renders conversation states, attachment, classification and suggestions',
    (tester) async {
      final suggestion = ConversationSuggestion(
        label: 'Open document',
        action: ConversationAction(
          id: 'suggestion-12345678',
          type: ConversationActionType.openAppDestination,
          parameters: const {'destination': 'library'},
        ),
      );
      ConversationSuggestion? selected;
      await tester.binding.setSurfaceSize(const Size(360, 640));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ConversationTranscript(
              messages: [
                message(
                  'user-12345678',
                  ConversationRole.user,
                  ConversationMessageKind.attachment,
                  'Read this bill',
                  data: const {'attachment_label': 'synthetic-bill.pdf'},
                ),
                message(
                  'result-12345678',
                  ConversationRole.assistant,
                  ConversationMessageKind.result,
                  'Finished reading your document.',
                  data: const {
                    'category': 'Finance',
                    'tags': ['invoice', 'test'],
                  },
                  suggestions: [suggestion],
                ),
                message(
                  'error-12345678',
                  ConversationRole.assistant,
                  ConversationMessageKind.error,
                  'That could not be completed.',
                ),
              ],
              loading: true,
              confirmation: null,
              onConfirm: () {},
              onCancelConfirmation: () {},
              onSuggestion: (value) => selected = value,
            ),
          ),
        ),
      );

      expect(find.text('synthetic-bill.pdf'), findsOneWidget);
      expect(find.text('Category: Finance'), findsOneWidget);
      expect(find.text('Tags: invoice, test'), findsOneWidget);
      expect(find.text('Working on that…'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Open document'));
      expect(selected, same(suggestion));
    },
  );

  testWidgets(
    'confirmation exposes labelled touch actions and expires safely',
    (tester) async {
      final semantics = tester.ensureSemantics();
      final action = ConversationAction(
        id: 'action-12345678',
        type: ConversationActionType.dismissInboxItem,
        parameters: const {'inbox_id': '11111111-1111-4111-8111-111111111111'},
      );
      var confirmed = false;
      final confirmation = ConversationConfirmation(
        action: action,
        summary: 'Dismiss this Inbox item?',
        targetLabel: 'Synthetic email',
        expiresAt: DateTime.now().add(const Duration(minutes: 5)),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: ConversationTranscript(
            messages: [
              message(
                'assistant-12345678',
                ConversationRole.assistant,
                ConversationMessageKind.confirmation,
                confirmation.summary,
              ),
            ],
            loading: false,
            confirmation: confirmation,
            onConfirm: () => confirmed = true,
            onCancelConfirmation: () {},
            onSuggestion: (_) {},
          ),
        ),
      );
      final node = tester.getSemantics(
        find.byKey(const ValueKey('conversation-message-assistant-12345678')),
      );
      expect(node.label, contains('FamilyDocuments: Dismiss this Inbox item?'));
      expect(
        tester.getSize(find.widgetWithText(FilledButton, 'Confirm')).height,
        greaterThanOrEqualTo(40),
      );
      await tester.tap(find.text('Confirm'));
      expect(confirmed, isTrue);
      semantics.dispose();
    },
  );
}
