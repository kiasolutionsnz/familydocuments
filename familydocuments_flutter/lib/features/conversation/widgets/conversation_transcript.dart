import 'package:flutter/material.dart';

import '../models/conversation_models.dart';

class ConversationTranscript extends StatelessWidget {
  const ConversationTranscript({
    super.key,
    required this.messages,
    required this.loading,
    required this.confirmation,
    required this.onConfirm,
    required this.onCancelConfirmation,
    required this.onSuggestion,
    this.activeClarificationId,
    this.onClarificationOption,
    this.onCancelClarification,
    this.onMoreCategories,
    this.scrollController,
    this.onOpenDocument,
  });

  final List<ConversationMessage> messages;
  final bool loading;
  final ConversationConfirmation? confirmation;
  final VoidCallback onConfirm;
  final VoidCallback onCancelConfirmation;
  final ValueChanged<ConversationSuggestion> onSuggestion;
  final String? activeClarificationId;
  final ValueChanged<ConversationClarificationOption>? onClarificationOption;
  final VoidCallback? onCancelClarification;
  final VoidCallback? onMoreCategories;
  final ScrollController? scrollController;
  final Future<void> Function(String)? onOpenDocument;

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'FamilyDocuments conversation',
    liveRegion: true,
    child: ListView.builder(
      controller: scrollController,
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 20),
      itemCount: messages.length + (loading ? 1 : 0),
      itemBuilder: (context, index) {
        if (index == messages.length) {
          return const _ThinkingBubble();
        }
        final message = messages[index];
        return _MessageBubble(
          message: message,
          confirmation: message.kind == ConversationMessageKind.confirmation
              ? confirmation
              : null,
          onConfirm: onConfirm,
          onCancelConfirmation: onCancelConfirmation,
          onSuggestion: onSuggestion,
          clarificationActive:
              message.clarificationId != null &&
              message.clarificationId == activeClarificationId,
          onClarificationOption: onClarificationOption,
          onCancelClarification: onCancelClarification,
          onMoreCategories: onMoreCategories,
          onOpenDocument: onOpenDocument,
        );
      },
    ),
  );
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({
    required this.message,
    required this.confirmation,
    required this.onConfirm,
    required this.onCancelConfirmation,
    required this.onSuggestion,
    required this.clarificationActive,
    required this.onClarificationOption,
    required this.onCancelClarification,
    required this.onMoreCategories,
    required this.onOpenDocument,
  });

  final ConversationMessage message;
  final ConversationConfirmation? confirmation;
  final VoidCallback onConfirm;
  final VoidCallback onCancelConfirmation;
  final ValueChanged<ConversationSuggestion> onSuggestion;
  final bool clarificationActive;
  final ValueChanged<ConversationClarificationOption>? onClarificationOption;
  final VoidCallback? onCancelClarification;
  final VoidCallback? onMoreCategories;
  final Future<void> Function(String)? onOpenDocument;

  @override
  Widget build(BuildContext context) {
    final user = message.role == ConversationRole.user;
    final error = message.kind == ConversationMessageKind.error;
    final progress = message.kind == ConversationMessageKind.progress;
    final background = user
        ? const Color(0xff17202e)
        : error
        ? const Color(0xfffff2f2)
        : const Color(0xfff6f8fb);
    final foreground = user
        ? Colors.white
        : error
        ? const Color(0xff932b2b)
        : const Color(0xff17243a);
    return Semantics(
      key: ValueKey('conversation-message-${message.id}'),
      label: '${user ? 'You' : 'FamilyDocuments'}: ${message.content}',
      child: Align(
        alignment: user ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
          constraints: const BoxConstraints(maxWidth: 680),
          margin: const EdgeInsets.only(bottom: 14),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.circular(18),
            border: user
                ? null
                : Border.all(
                    color: error
                        ? const Color(0xffefc3c3)
                        : const Color(0xffe2e7ef),
                  ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (progress) ...[
                const LinearProgressIndicator(minHeight: 3),
                const SizedBox(height: 10),
              ],
              if (message.kind == ConversationMessageKind.attachment &&
                  message.data['attachment_label'] != null) ...[
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.attach_file, size: 18, color: foreground),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        message.data['attachment_label'].toString(),
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: foreground,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
              ],
              Text(message.content, style: TextStyle(color: foreground)),
              if (message.data['results'] is List &&
                  (message.data['results'] as List).isNotEmpty) ...[
                const SizedBox(height: 10),
                ...(message.data['results'] as List)
                    .whereType<Map>()
                    .take(5)
                    .map(
                      (result) => Container(
                        width: double.infinity,
                        margin: const EdgeInsets.only(bottom: 8),
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          border: Border.all(color: const Color(0xffdce3ec)),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              result['title']?.toString() ?? 'Saved item',
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            if (result['category'] != null)
                              Text(result['category'].toString()),
                            if (onOpenDocument != null &&
                                result['type'] != 'reminder' &&
                                result['type'] != 'link' &&
                                result['id'] is String &&
                                (result['match_type'] == 'ocr' ||
                                    result['match_type'] == 'metadata'))
                              TextButton.icon(
                                key: ValueKey('open-document-${result['id']}'),
                                onPressed: () =>
                                    onOpenDocument!(result['id'] as String),
                                icon: const Icon(Icons.visibility_outlined),
                                label: const Text('Open document'),
                              ),
                            if (result['type'] == 'reminder') ...[
                              Text(
                                [
                                  result['due_date'],
                                  result['due_time'],
                                ].where((value) => value != null).join(' at '),
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: Color(0xff64748b),
                                ),
                              ),
                            ] else
                              Text(
                                result['match_type'] == 'ocr'
                                    ? 'Matched document text'
                                    : 'Matched saved details',
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: Color(0xff64748b),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
              ],
              if (onOpenDocument != null &&
                  message.data['document_id'] is String)
                TextButton.icon(
                  key: ValueKey('open-document-${message.data['document_id']}'),
                  onPressed: () =>
                      onOpenDocument!(message.data['document_id'] as String),
                  icon: const Icon(Icons.visibility_outlined),
                  label: const Text('Open document'),
                ),
              if (message.data['category'] != null ||
                  message.data['tags'] is List) ...[
                const SizedBox(height: 10),
                if (message.data['category'] != null)
                  Text(
                    'Category: ${message.data['category']}',
                    style: TextStyle(color: foreground),
                  ),
                if (message.data['tags'] is List &&
                    (message.data['tags'] as List).isNotEmpty)
                  Text(
                    'Tags: ${(message.data['tags'] as List).join(', ')}',
                    style: TextStyle(color: foreground),
                  ),
              ],
              if (confirmation != null) ...[
                const SizedBox(height: 10),
                Text(
                  confirmation!.targetLabel,
                  style: TextStyle(
                    color: foreground,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton(
                      onPressed: confirmation!.expired ? null : onConfirm,
                      child: Text(
                        message.data['feedback_confirmation'] == true
                            ? 'Add feedback'
                            : 'Confirm',
                      ),
                    ),
                    OutlinedButton(
                      onPressed: confirmation!.expired
                          ? null
                          : onCancelConfirmation,
                      child: const Text('Cancel'),
                    ),
                  ],
                ),
              ],
              if (clarificationActive) ...[
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    ...message.clarificationOptions.map(
                      (option) => ActionChip(
                        label: Text(option.label),
                        onPressed: onClarificationOption == null
                            ? null
                            : () => onClarificationOption!(option),
                      ),
                    ),
                    if (message.offersMoreCategories)
                      OutlinedButton(
                        key: const ValueKey('more-conversation-categories'),
                        onPressed: onMoreCategories,
                        child: const Text('More categories'),
                      ),
                    OutlinedButton(
                      onPressed: onCancelClarification,
                      child: const Text('Cancel'),
                    ),
                  ],
                ),
              ],
              if (message.suggestions.isNotEmpty) ...[
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: message.suggestions
                      .take(3)
                      .map(
                        (suggestion) => ActionChip(
                          label: Text(suggestion.label),
                          onPressed: () => onSuggestion(suggestion),
                        ),
                      )
                      .toList(),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _ThinkingBubble extends StatelessWidget {
  const _ThinkingBubble();

  @override
  Widget build(BuildContext context) => const Align(
    alignment: Alignment.centerLeft,
    child: Padding(
      padding: EdgeInsets.only(bottom: 14),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Color(0xfff6f8fb),
          borderRadius: BorderRadius.all(Radius.circular(18)),
        ),
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              SizedBox(width: 10),
              Text('Working on that…'),
            ],
          ),
        ),
      ),
    ),
  );
}
