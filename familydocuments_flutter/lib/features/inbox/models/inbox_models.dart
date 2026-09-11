enum InboxFilter { all, unreviewed, attachments, links, telegram, reviewed }

class InboxLocation {
  const InboxLocation({this.messageId});
  final String? messageId;
  String get value => messageId == null ? 'inbox' : 'inbox/$messageId';
  static InboxLocation parse(String value) {
    final parts = value.split('/');
    if (parts.firstOrNull != 'inbox' || parts.length > 2) {
      return const InboxLocation();
    }
    return InboxLocation(messageId: parts.length == 2 ? parts[1] : null);
  }
}

class InboxCategory {
  const InboxCategory({required this.id, required this.name});
  final String id, name;
  factory InboxCategory.fromJson(Map value) => InboxCategory(
    id: value['id']?.toString() ?? '',
    name: value['name']?.toString() ?? 'Category',
  );
}

class InboxItem {
  const InboxItem({
    required this.id,
    required this.sender,
    required this.subject,
    required this.receivedAt,
    required this.source,
    required this.preview,
    required this.attachmentCount,
    required this.linkCount,
    required this.reviewState,
    required this.updatedAt,
    required this.actions,
  });
  final String id, sender, subject, source, preview, reviewState;
  final DateTime receivedAt, updatedAt;
  final int attachmentCount, linkCount;
  final List<String> actions;

  factory InboxItem.fromJson(Map value) => InboxItem(
    id: value['id']?.toString() ?? '',
    sender: value['sender']?.toString() ?? 'Unknown sender',
    subject: value['subject']?.toString().trim().isNotEmpty == true
        ? value['subject'].toString()
        : 'Message',
    receivedAt:
        DateTime.tryParse(value['received_at']?.toString() ?? '')?.toLocal() ??
        DateTime.fromMillisecondsSinceEpoch(0),
    source: value['source']?.toString() ?? 'Email',
    preview: value['preview']?.toString() ?? '',
    attachmentCount: (value['attachment_count'] as num?)?.toInt() ?? 0,
    linkCount: (value['link_count'] as num?)?.toInt() ?? 0,
    reviewState: value['review_state']?.toString() ?? 'unreviewed',
    updatedAt:
        DateTime.tryParse(value['updated_at']?.toString() ?? '')?.toLocal() ??
        DateTime.fromMillisecondsSinceEpoch(0),
    actions:
        (value['actions'] as List?)?.map((x) => x.toString()).toList() ??
        const [],
  );
}

class InboxAttachment {
  const InboxAttachment({
    required this.id,
    required this.fileName,
    required this.mimeType,
    required this.sizeBytes,
    required this.status,
  });
  final String id, fileName, mimeType, status;
  final int sizeBytes;
  bool get canSave => status == 'clean';
  factory InboxAttachment.fromJson(Map value) => InboxAttachment(
    id: value['id']?.toString() ?? '',
    fileName: value['file_name']?.toString() ?? 'Attachment',
    mimeType: value['mime_type']?.toString() ?? 'application/octet-stream',
    sizeBytes: (value['size_bytes'] as num?)?.toInt() ?? 0,
    status: value['status']?.toString() ?? 'pending',
  );
}

class InboxMessage {
  const InboxMessage({
    required this.id,
    required this.sender,
    required this.recipients,
    required this.subject,
    required this.receivedAt,
    required this.source,
    required this.bodyText,
    required this.reviewState,
    required this.updatedAt,
    required this.canEdit,
    required this.attachments,
    required this.links,
    required this.actions,
  });
  final String id, sender, subject, source, bodyText, reviewState;
  final List<String> recipients, links, actions;
  final DateTime receivedAt, updatedAt;
  final bool canEdit;
  final List<InboxAttachment> attachments;

  factory InboxMessage.fromJson(Map value) => InboxMessage(
    id: value['id']?.toString() ?? '',
    sender: value['sender']?.toString() ?? 'Unknown sender',
    recipients:
        (value['recipients'] as List?)?.map((x) => x.toString()).toList() ??
        const [],
    subject: value['subject']?.toString() ?? 'Message',
    receivedAt:
        DateTime.tryParse(value['received_at']?.toString() ?? '')?.toLocal() ??
        DateTime.fromMillisecondsSinceEpoch(0),
    source: value['source']?.toString() ?? 'Email',
    bodyText: value['body_text']?.toString() ?? '',
    reviewState: value['review_state']?.toString() ?? 'unreviewed',
    updatedAt:
        DateTime.tryParse(value['updated_at']?.toString() ?? '')?.toLocal() ??
        DateTime.fromMillisecondsSinceEpoch(0),
    canEdit: value['can_edit'] == true,
    attachments: _maps(value['attachments'])
        .map(InboxAttachment.fromJson)
        .toList(),
    links:
        (value['links'] as List?)?.map((x) => x.toString()).toList() ??
        const [],
    actions: _maps(value['actions'])
        .map((x) => x['type']?.toString() ?? '')
        .where((x) => x.isNotEmpty)
        .toList(),
  );
}

class InboxData {
  const InboxData({
    required this.canEdit,
    required this.total,
    required this.items,
    required this.categories,
    required this.tags,
    required this.linkCategories,
  });
  final bool canEdit;
  final int total;
  final List<InboxItem> items;
  final List<InboxCategory> categories, linkCategories;
  final List<String> tags;
  factory InboxData.fromJson(Map value) => InboxData(
    canEdit: value['can_edit'] == true,
    total: (value['total'] as num?)?.toInt() ?? 0,
    items: _maps(value['items']).map(InboxItem.fromJson).toList(),
    categories: _maps(value['categories']).map(InboxCategory.fromJson).toList(),
    tags:
        (value['tags'] as List?)?.map((x) => x.toString()).toList() ?? const [],
    linkCategories: _maps(value['link_categories'])
        .map(InboxCategory.fromJson)
        .toList(),
  );
}

class InboxActionResult {
  const InboxActionResult({
    this.documentId,
    this.jobId,
    this.duplicate = false,
  });
  final String? documentId, jobId;
  final bool duplicate;
}

List<Map> _maps(dynamic value) =>
    (value as List?)?.whereType<Map>().toList() ?? const [];

extension _FirstOrNull<T> on List<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
