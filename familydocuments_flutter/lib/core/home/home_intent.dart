enum HomeIntentType {
  search,
  saveAttachment,
  readAttachment,
  invoiceAttachment,
  vagueAttachment,
  reminder,
  viewCategory,
  clarification,
}

class HomeIntent {
  const HomeIntent(this.type, {this.destination, this.reminderTitle});
  final HomeIntentType type;
  final String? destination;
  final String? reminderTitle;
}

/// Deliberately small and deterministic. This only recognises actions which
/// have a corresponding FamilyDocuments capability; it is not a chat model.
HomeIntent parseHomeIntent(String message, {required bool hasAttachment}) {
  final text = message.trim();
  final lower = text.toLowerCase();
  final destination = RegExp(
    r'\b(?:add|save|put|keep)\s+(?:this\s+)?(?:under|to|in|with)\s+(.+)$',
    caseSensitive: false,
  ).firstMatch(text)?.group(1)?.trim().replaceFirst(RegExp(r'[.!?]+$'), '');
  final asksInvoice = RegExp(r'\b(invoice|bill)\b').hasMatch(lower);
  final asksRead = RegExp(r'\b(read|scan|ocr|extract|due date)\b')
      .hasMatch(lower);

  if (hasAttachment) {
    if (destination != null && !asksRead && !asksInvoice) {
      return HomeIntent(
        HomeIntentType.saveAttachment,
        destination: destination,
      );
    }
    if (asksInvoice) return const HomeIntent(HomeIntentType.invoiceAttachment);
    if (asksRead) return const HomeIntent(HomeIntentType.readAttachment);
    return const HomeIntent(HomeIntentType.vagueAttachment);
  }

  if (lower.startsWith('remind me') ||
      lower.startsWith('add reminder') ||
      (RegExp(r'\b(appointment|meeting|reminder)\b').hasMatch(lower) &&
          RegExp(r'\b(tomorrow|on\s+\d{1,2}\s+[a-z]+|next month)\b')
              .hasMatch(lower))) {
    final title = text
        .replaceFirst(
          RegExp(
            r'^(remind me|add reminder)\s*(about)?\s*',
            caseSensitive: false,
          ),
          '',
        )
        .trim();
    return HomeIntent(HomeIntentType.reminder, reminderTitle: title);
  }
  if (RegExp(r'\b(find|show|where is|search)\b').hasMatch(lower)) {
    return const HomeIntent(HomeIntentType.search);
  }
  if (RegExp(
    r'^(travel|rentals?|medical|insurance|home|finance|documents?)$',
    caseSensitive: false,
  ).hasMatch(lower)) {
    return const HomeIntent(HomeIntentType.viewCategory);
  }
  return const HomeIntent(HomeIntentType.clarification);
}

String? metadataCategoryHint(String filename) {
  final name = filename.toLowerCase();
  if (RegExp(r'\b(tenancy|lease|rental|inspection|landlord)\b')
      .hasMatch(name)) {
    return 'Rentals';
  }
  if (RegExp(r'\b(passport|visa|flight|hotel|travel)\b').hasMatch(name)) {
    return 'Travel';
  }
  if (RegExp(r'\b(insurance|policy)\b').hasMatch(name)) {
    return 'Insurance';
  }
  if (RegExp(r'\b(medical|doctor|health)\b').hasMatch(name)) {
    return 'Medical';
  }
  return null;
}
