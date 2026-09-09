enum TimelineItemKind { document, link, message, reminder }

class TimelineCursor {
  const TimelineCursor({required this.occurredAt, required this.key});

  final DateTime occurredAt;
  final String key;
}

class TimelineItem {
  const TimelineItem({
    required this.id,
    required this.eventKey,
    required this.kind,
    required this.eventType,
    required this.title,
    required this.occurredAt,
    this.context,
    this.status,
    this.documentId,
    this.jobId,
    this.category,
    this.tags = const [],
    this.url,
    this.retryAllowed = false,
  });

  final String id;
  final String eventKey;
  final TimelineItemKind kind;
  final String eventType;
  final String title;
  final String? context;
  final DateTime occurredAt;
  final String? status;
  final String? documentId;
  final String? jobId;
  final String? category;
  final List<String> tags;
  final String? url;
  final bool retryAllowed;

  bool get isActive =>
      kind == TimelineItemKind.document &&
      {'queued', 'retry_wait', 'processing'}.contains(status);

  bool get isFailed =>
      kind == TimelineItemKind.document &&
      {'failed', 'permanent_failed'}.contains(status);

  TimelineItem copyWith({
    String? title,
    String? context,
    DateTime? occurredAt,
    String? status,
    String? category,
    List<String>? tags,
    bool? retryAllowed,
  }) => TimelineItem(
    id: id,
    eventKey: eventKey,
    kind: kind,
    eventType: eventType,
    title: title ?? this.title,
    context: context ?? this.context,
    occurredAt: occurredAt ?? this.occurredAt,
    status: status ?? this.status,
    documentId: documentId,
    jobId: jobId,
    category: category ?? this.category,
    tags: tags ?? this.tags,
    url: url,
    retryAllowed: retryAllowed ?? this.retryAllowed,
  );

  static TimelineItem fromJson(Map<String, dynamic> value) {
    final kind = switch (value['kind']?.toString()) {
      'link' => TimelineItemKind.link,
      'message' => TimelineItemKind.message,
      'reminder' => TimelineItemKind.reminder,
      _ => TimelineItemKind.document,
    };
    return TimelineItem(
      id: value['id']?.toString() ?? value['event_key']?.toString() ?? '',
      eventKey: value['event_key']?.toString() ?? '',
      kind: kind,
      eventType: value['event_type']?.toString() ?? '',
      title: value['title']?.toString() ?? 'Timeline item',
      context: value['context']?.toString(),
      occurredAt:
          DateTime.tryParse(value['occurred_at']?.toString() ?? '')
              ?.toLocal() ??
          DateTime.fromMillisecondsSinceEpoch(0),
      status: value['status']?.toString(),
      documentId: value['document_id']?.toString(),
      jobId: value['job_id']?.toString(),
      category: value['category']?.toString(),
      tags:
          (value['tags'] as List?)
              ?.map((tag) => tag.toString())
              .where((tag) => tag.isNotEmpty)
              .toList() ??
          const [],
      url: value['url']?.toString(),
      retryAllowed: value['retry_allowed'] == true,
    );
  }
}

class TimelinePageData {
  const TimelinePageData({
    required this.items,
    required this.hasMore,
    this.nextCursor,
  });

  final List<TimelineItem> items;
  final bool hasMore;
  final TimelineCursor? nextCursor;
}
