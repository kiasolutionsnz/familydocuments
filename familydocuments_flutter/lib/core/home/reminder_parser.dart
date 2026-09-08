class ParsedReminder {
  const ParsedReminder({
    required this.title,
    required this.dueDate,
    this.dueTime,
    required this.displayWhen,
  });
  final String title, dueDate, displayWhen;
  final String? dueTime;
}

class ReminderClarification implements Exception {
  const ReminderClarification(this.message);
  final String message;
}

ParsedReminder parseReminderCommand(String command, {DateTime? now}) {
  final text = command.trim();
  final lower = text.toLowerCase();
  final today = _aucklandDate(now ?? DateTime.now().toUtc());
  if (RegExp(r'\b(sometime\s+)?next month\b').hasMatch(lower)) {
    throw const ReminderClarification('What date next month should I use?');
  }
  if (RegExp(r'\b(monday|tuesday|wednesday|thursday|friday|saturday|sunday)\b')
      .hasMatch(lower)) {
    throw const ReminderClarification('Which date do you mean?');
  }
  DateTime due;
  String datePhrase;
  if (lower.contains('tomorrow')) {
    due = today.add(const Duration(days: 1));
    datePhrase = 'tomorrow';
  } else {
    final match = RegExp(
      r'\bon\s+(\d{1,2})\s+(january|february|march|april|may|june|july|august|september|october|november|december)(?:\s+(20\d\d))?',
      caseSensitive: false,
    ).firstMatch(text);
    if (match == null) {
      throw const ReminderClarification('What date should I use?');
    }
    final month = _months.indexOf(match.group(2)!.toLowerCase()) + 1;
    var year = int.tryParse(match.group(3) ?? '') ?? today.year;
    due = DateTime(year, month, int.parse(match.group(1)!));
    if (match.group(3) == null && due.isBefore(today)) {
      due = DateTime(++year, month, int.parse(match.group(1)!));
    }
    if (due.month != month) {
      throw const ReminderClarification(
        'That date is not valid. Which date should I use?',
      );
    }
    datePhrase =
        '${due.day} ${_months[month - 1][0].toUpperCase()}${_months[month - 1].substring(1)}';
  }
  final timeMatch = RegExp(
    r'\bat\s+(\d{1,2})(?::(\d{2}))?\s*(am|pm)\b',
    caseSensitive: false,
  ).firstMatch(text);
  String? dueTime;
  String displayWhen = datePhrase;
  if (timeMatch != null) {
    var hour = int.parse(timeMatch.group(1)!);
    final minute = int.tryParse(timeMatch.group(2) ?? '0') ?? 0;
    final period = timeMatch.group(3)!.toLowerCase();
    if (hour < 1 || hour > 12 || minute > 59) {
      throw const ReminderClarification('What time should I use?');
    }
    if (period == 'pm' && hour != 12) hour += 12;
    if (period == 'am' && hour == 12) hour = 0;
    if (hour == 2 && _isAucklandClockChangeDate(due)) {
      throw const ReminderClarification(
        'That time changes with daylight saving. What other time should I use?',
      );
    }
    dueTime =
        '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}:00';
    final shownHour = int.parse(timeMatch.group(1)!);
    displayWhen =
        '$datePhrase at $shownHour:${minute.toString().padLeft(2, '0')} $period';
  }
  var title = text
      .replaceFirst(
        RegExp(
          r'^(remind me\s+(?:about|to)?|add reminder)\s*',
          caseSensitive: false,
        ),
        '',
      )
      .replaceAll(RegExp(r'\s+tomorrow\b', caseSensitive: false), '')
      .replaceAll(
        RegExp(r'\s+on\s+\d{1,2}\s+[a-z]+(?:\s+20\d\d)?', caseSensitive: false),
        '',
      )
      .replaceAll(
        RegExp(
          r'\s+at\s+\d{1,2}(?::\d{2})?\s*(?:am|pm)\b',
          caseSensitive: false,
        ),
        '',
      )
      .trim();
  if (title.isEmpty) {
    throw const ReminderClarification('What should I remind you about?');
  }
  title = '${title[0].toUpperCase()}${title.substring(1)}';
  return ParsedReminder(
    title: title,
    dueDate:
        '${due.year.toString().padLeft(4, '0')}-${due.month.toString().padLeft(2, '0')}-${due.day.toString().padLeft(2, '0')}',
    dueTime: dueTime,
    displayWhen: displayWhen,
  );
}

bool _isAucklandClockChangeDate(DateTime date) {
  var aprilDay = 1;
  while (DateTime(date.year, 4, aprilDay).weekday != DateTime.sunday) {
    aprilDay++;
  }
  var septemberDay = 30;
  while (DateTime(date.year, 9, septemberDay).weekday != DateTime.sunday) {
    septemberDay--;
  }
  return (date.month == 4 && date.day == aprilDay) ||
      (date.month == 9 && date.day == septemberDay);
}

DateTime _aucklandDate(DateTime utc) {
  final year = utc.year;
  final dstStart = _lastSundayUtc(year, 9).subtract(const Duration(hours: 10));
  final dstEnd = _firstSundayUtc(year, 4).subtract(const Duration(hours: 10));
  final isDst = utc.isBefore(dstEnd) || !utc.isBefore(dstStart);
  final local = utc.add(Duration(hours: isDst ? 13 : 12));
  return DateTime(local.year, local.month, local.day);
}

DateTime _lastSundayUtc(int year, int month) {
  var day = DateTime.utc(year, month + 1, 0);
  while (day.weekday != DateTime.sunday) {
    day = day.subtract(const Duration(days: 1));
  }
  return day;
}

DateTime _firstSundayUtc(int year, int month) {
  var day = DateTime.utc(year, month, 1);
  while (day.weekday != DateTime.sunday) {
    day = day.add(const Duration(days: 1));
  }
  return day;
}

const _months = [
  'january',
  'february',
  'march',
  'april',
  'may',
  'june',
  'july',
  'august',
  'september',
  'october',
  'november',
  'december',
];
