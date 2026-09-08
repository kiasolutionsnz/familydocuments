import 'package:familydocuments_flutter/core/home/reminder_parser.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parses a standalone reminder into explicit Auckland date and time', () {
    final result = parseReminderCommand(
      'Remind me about my doctor appointment tomorrow at 2 pm',
      now: DateTime.utc(2026, 9, 8),
    );
    expect(result.title, 'My doctor appointment');
    expect(result.dueDate, '2026-09-09');
    expect(result.dueTime, '14:00:00');
    expect(result.displayWhen, 'tomorrow at 2:00 pm');
  });

  test('parses an explicit calendar date', () {
    final result = parseReminderCommand(
      'Dentist appointment on 18 September at 9:30 am',
      now: DateTime.utc(2026, 9, 8),
    );
    expect(result.title, 'Dentist appointment');
    expect(result.dueDate, '2026-09-18');
    expect(result.dueTime, '09:30:00');
  });

  test('asks for clarification instead of guessing ambiguous dates', () {
    expect(
      () => parseReminderCommand('Remind me sometime next month'),
      throwsA(isA<ReminderClarification>()),
    );
    expect(
      () => parseReminderCommand('Appointment Friday'),
      throwsA(isA<ReminderClarification>()),
    );
  });

  test('clarifies Auckland daylight-saving gap and overlap times', () {
    for (final command in [
      'Appointment on 27 September 2026 at 2:30 am',
      'Appointment on 5 April 2026 at 2:30 am',
    ]) {
      expect(
        () => parseReminderCommand(command, now: DateTime.utc(2026, 1, 1)),
        throwsA(
          isA<ReminderClarification>().having(
            (value) => value.message,
            'message',
            contains('daylight saving'),
          ),
        ),
        reason: command,
      );
    }
  });
}
