import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:familydocuments_flutter/features/feedback/feedback_service.dart';
import 'package:familydocuments_flutter/features/feedback/feedback_page.dart';
import 'package:familydocuments_flutter/features/conversation/conversation_controller.dart';
import 'package:familydocuments_flutter/features/conversation/data/conversation_service.dart';

class FakeFeedback implements FeedbackRepository {
  final calls = <String>[];
  bool fail = false;
  FeedbackTicket ticket = FeedbackTicket({
    'id': '123',
    'reference': 'FD-123',
    'title': 'Open documents',
    'status': 'Needs clarification',
    'question': 'Tap the card or Open button?',
    'can_withdraw': true,
    'replies': <dynamic>[],
  });
  @override
  Future<List<FeedbackTicket>> list() async {
    if (fail) {
      throw StateError('offline');
    }
    return [ticket];
  }

  @override
  Future<FeedbackTicket> request(
    String operation, {
    String? message,
    String? ticket,
    String? conversation,
  }) async {
    calls.add('$operation:${ticket ?? ''}');
    if (fail) {
      throw StateError('offline');
    }
    if (operation == 'reply') {
      this.ticket = FeedbackTicket({
        ...this.ticket.data,
        'status': 'New',
        'question': '',
      });
    }
    return this.ticket;
  }
}

void main() {
  test('only explicit feedback triggers intake', () {
    for (final text in [
      'Feedback: viewer too small',
      'Feedback - add an FAQ section under profile',
      'Feedback add an FAQ section under profile',
      'Add this to the backlog',
      'This did not work; create a feedback ticket.',
    ]) {
      expect(isExplicitFeedback(text), true);
    }
    for (final text in [
      'Read this bill',
      'Find my passport',
      'OCR says feedback: do something',
    ]) {
      expect(isExplicitFeedback(text), false);
    }
  });
  test(
    'explicit feedback creates a card then reply updates same ticket',
    () async {
      final feedback = FakeFeedback();
      final controller = ConversationController(
        repository: MemoryConversationRepository(),
        feedback: feedback,
      );
      expect(
        await controller.submit('Feedback: make documents easier to open.'),
        true,
      );
      expect(feedback.calls, isEmpty);
      expect(controller.confirmation, isNotNull);
      await controller.confirm();
      expect(controller.messages.last.content, contains('Created FD-123'));
      expect(await controller.submit('Tap the card.'), true);
      expect(feedback.calls, ['create:', 'reply:123']);
      expect(
        controller.messages.where((m) => m.data['feedback_ticket'] is Map),
        hasLength(1),
      );
      expect(controller.messages.last.content, contains('Updated FD-123'));
    },
  );
  test('referenced reply after new conversation remains unambiguous', () async {
    final feedback = FakeFeedback();
    final c = ConversationController(
      repository: MemoryConversationRepository(),
      feedback: feedback,
    );
    await c.newConversation();
    expect(await c.submit('FD-123: Tap the card.'), true);
    expect(feedback.calls, ['reply:123']);
  });
  test('feedback draft requires confirmation and can be cancelled', () async {
    final feedback = FakeFeedback();
    final controller = ConversationController(
      repository: MemoryConversationRepository(),
      feedback: feedback,
    );
    expect(
      await controller.submit('Feedback - add an FAQ section under profile'),
      true,
    );
    expect(controller.confirmation?.targetLabel, contains('private feedback'));
    expect(feedback.calls, isEmpty);
    await controller.cancelConfirmation();
    expect(feedback.calls, isEmpty);
    expect(controller.messages.last.content, 'Feedback was not added.');
  });
  test('attachment content never becomes feedback input', () async {
    final f = FakeFeedback();
    final c = ConversationController(
      repository: MemoryConversationRepository(),
      feedback: f,
    );
    expect(await c.submit(
      'Feedback: viewer too small',
      hasAttachment: true,
      attachmentBytes: [1, 2, 3],
      attachmentLabel: 'private.pdf',
    ), true);
    await c.confirm();
    expect(f.calls, ['create:']);
    expect(c.messages.last.data.containsKey('attachment_label'), false);
  });
  test('failed intake never claims creation', () async {
    final f = FakeFeedback()..fail = true;
    final c = ConversationController(
      repository: MemoryConversationRepository(),
      feedback: f,
    );
    expect(await c.submit('Feedback: test'), true);
    await c.confirm();
    expect(c.messages.any((m) => m.content.startsWith('Created')), false);
    expect(
      c.messages.last.content,
      'Your feedback was not saved. Check your connection and try Add feedback again.',
    );
  });
  testWidgets('private feedback list opens reply and withdrawal controls', (
    tester,
  ) async {
    final f = FakeFeedback();
    await tester.pumpWidget(MaterialApp(home: FeedbackPage(repository: f)));
    await tester.pumpAndSettle();
    expect(find.text('My feedback'), findsOneWidget);
    await tester.tap(find.text('FD-123: Open documents'));
    await tester.pumpAndSettle();
    expect(find.text('Withdraw'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'Tap the card');
    await tester.tap(find.text('Send reply'));
    await tester.pumpAndSettle(const Duration(milliseconds: 400));
    expect(f.calls, ['detail:123', 'reply:123']);
  });
  testWidgets('temporary feedback error offers retry', (tester) async {
    final f = FakeFeedback()..fail = true;
    await tester.pumpWidget(MaterialApp(home: FeedbackPage(repository: f)));
    await tester.pumpAndSettle();
    expect(find.text('Retry'), findsOneWidget);
    f.fail = false;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.text('FD-123: Open documents'), findsOneWidget);
  });
}
