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
  testWidgets('grounded search and saved result open their document IDs', (
    tester,
  ) async {
    final opened = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ConversationTranscript(
            messages: [
              message(
                'search',
                ConversationRole.assistant,
                ConversationMessageKind.result,
                'I found these documents.',
                data: const {
                  'results': [
                    {
                      'id': 'document-one',
                      'title': 'Passport',
                      'match_type': 'metadata',
                    },
                    {
                      'id': 'document-two',
                      'title': 'Invoice',
                      'match_type': 'ocr',
                    },
                  ],
                },
              ),
              message(
                'saved',
                ConversationRole.assistant,
                ConversationMessageKind.result,
                'Saved.',
                data: const {'document_id': 'document-three'},
              ),
            ],
            loading: false,
            confirmation: null,
            onConfirm: () {},
            onCancelConfirmation: () {},
            onSuggestion: (_) {},
            onOpenDocument: (id) async => opened.add(id),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    for (final id in ['document-one', 'document-two', 'document-three']) {
      await tester.tap(find.byKey(ValueKey('open-document-$id')));
      await tester.pump();
    }
    expect(opened, ['document-one', 'document-two', 'document-three']);
  });
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

  testWidgets('clarification renders trusted options and Cancel', (
    tester,
  ) async {
    ConversationClarificationOption? selected;
    var cancelled = false;
    const clarificationId = '11111111-1111-4111-8111-111111111111';
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ConversationTranscript(
            messages: [
              message(
                'clarification-12345678',
                ConversationRole.assistant,
                ConversationMessageKind.clarification,
                'What would you like me to do?',
                data: const {
                  'clarification_id': clarificationId,
                  'choices': ['Show reminders'],
                  'choice_actions': [
                    {
                      'id': 'option-reminders-1234',
                      'type': 'query_reminders',
                      'version': 1,
                      'parameters': {'scope': 'upcoming'},
                    },
                  ],
                },
              ),
            ],
            loading: false,
            confirmation: null,
            activeClarificationId: clarificationId,
            onConfirm: () {},
            onCancelConfirmation: () {},
            onSuggestion: (_) {},
            onClarificationOption: (value) => selected = value,
            onCancelClarification: () => cancelled = true,
          ),
        ),
      ),
    );

    expect(find.text('Show reminders'), findsOneWidget);
    expect(find.text('Cancel'), findsOneWidget);
    await tester.tap(find.text('Show reminders'));
    expect(selected?.id, 'option-reminders-1234');
    await tester.tap(find.text('Cancel'));
    expect(cancelled, isTrue);
  });

  testWidgets('reminder result renders its local date and time', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ConversationTranscript(
          messages: [
            message(
              'reminders-12345678',
              ConversationRole.assistant,
              ConversationMessageKind.result,
              'Here are your reminders for today.',
              data: const {
                'results': [
                  {
                    'type': 'reminder',
                    'title': 'Doctor appointment',
                    'due_date': '2027-01-20',
                    'due_time': '14:00:00',
                  },
                ],
              },
            ),
          ],
          loading: false,
          confirmation: null,
          onConfirm: () {},
          onCancelConfirmation: () {},
          onSuggestion: (_) {},
        ),
      ),
    );

    expect(find.text('Doctor appointment'), findsOneWidget);
    expect(find.text('2027-01-20 at 14:00:00'), findsOneWidget);
  });

  testWidgets('document category clarification exposes More categories', (
    tester,
  ) async {
    var opened = false;
    const clarificationId = '11111111-1111-4111-8111-111111111111';
    await tester.pumpWidget(
      MaterialApp(
        home: ConversationTranscript(
          messages: [
            message(
              'category-clarification',
              ConversationRole.assistant,
              ConversationMessageKind.clarification,
              'Which category should I use?',
              data: const {
                'clarification_id': clarificationId,
                'action': {
                  'id': 'category-action-1234',
                  'type': 'request_clarification',
                  'version': 1,
                  'parameters': {
                    'question': 'Which category should I use?',
                    'missing_parameter': 'document_category',
                    'attachment_id': '22222222-2222-4222-8222-222222222222',
                  },
                },
              },
            ),
          ],
          loading: false,
          confirmation: null,
          activeClarificationId: clarificationId,
          onConfirm: () {},
          onCancelConfirmation: () {},
          onSuggestion: (_) {},
          onMoreCategories: () => opened = true,
        ),
      ),
    );
    await tester.tap(find.text('More categories'));
    expect(opened, isTrue);
  });
}
