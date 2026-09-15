class ReminderItem {
  const ReminderItem({
    required this.id,
    required this.title,
    required this.dueAt,
    required this.status,
    required this.dueState,
    required this.recurrence,
    required this.audience,
    this.dueTime,
    this.categoryName,
    this.documentTitle,
    this.completionKind,
  });

  final String id, title, status, dueState, recurrence, audience;
  final DateTime dueAt;
  final String? dueTime, categoryName, documentTitle, completionKind;

  bool get active => status == 'upcoming';

  factory ReminderItem.fromJson(Map value) => ReminderItem(
    id: value['id']?.toString() ?? '',
    title: value['title']?.toString() ?? 'Reminder',
    dueAt:
        DateTime.tryParse(value['due_at']?.toString() ?? '') ??
        DateTime.fromMillisecondsSinceEpoch(0),
    dueTime: value['due_time']?.toString(),
    status: value['status']?.toString() ?? 'upcoming',
    dueState: value['due_state']?.toString() ?? 'upcoming',
    recurrence: value['recurrence']?.toString() ?? 'none',
    audience: value['audience']?.toString() ?? 'personal',
    categoryName: value['category_name']?.toString(),
    documentTitle: value['document_title']?.toString(),
    completionKind: value['completion_kind']?.toString(),
  );
}

class ReminderDashboard {
  const ReminderDashboard({
    required this.items,
    this.emailEnabled = true,
    this.deliveryHistory = const [],
  });
  final List<ReminderItem> items;
  final bool emailEnabled;
  final List<ReminderDelivery> deliveryHistory;
  factory ReminderDashboard.fromJson(Map value) => ReminderDashboard(
    items: (value['items'] as List? ?? const [])
        .whereType<Map>()
        .map(ReminderItem.fromJson)
        .toList(),
  );
}

class ReminderDelivery {
  const ReminderDelivery({
    required this.subject,
    required this.status,
    required this.createdAt,
    this.sentAt,
  });
  final String subject, status;
  final DateTime createdAt;
  final DateTime? sentAt;
  factory ReminderDelivery.fromJson(Map value) => ReminderDelivery(
    subject: value['subject']?.toString() ?? 'Reminder email',
    status: value['status']?.toString() ?? 'pending',
    createdAt:
        DateTime.tryParse(value['created_at']?.toString() ?? '') ??
        DateTime.fromMillisecondsSinceEpoch(0),
    sentAt: DateTime.tryParse(value['sent_at']?.toString() ?? ''),
  );
}
