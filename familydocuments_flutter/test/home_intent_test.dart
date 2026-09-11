import 'package:familydocuments_flutter/core/home/home_intent.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('explicit attachment destination saves without OCR', () {
    final intent = parseHomeIntent(
      'Save this under Rentals',
      hasAttachment: true,
    );
    expect(intent.type, HomeIntentType.saveAttachment);
    expect(intent.destination, 'Rentals');
    final natural = parseHomeIntent('Save this as rental', hasAttachment: true);
    expect(natural.type, HomeIntentType.saveAttachment);
    expect(natural.destination, 'rental');
  });

  test('invoice attachment explicitly requests OCR', () {
    expect(
      parseHomeIntent('Read this bill as an invoice', hasAttachment: true).type,
      HomeIntentType.invoiceAttachment,
    );
  });

  test('OCR request synonyms are case-insensitive', () {
    for (final command in const [
      'Add the document and do ocr',
      'Perform OCR',
      'READ this document',
      'Scan this document',
      'Extract the text',
    ]) {
      expect(
        parseHomeIntent(command, hasAttachment: true).type,
        HomeIntentType.readAttachment,
        reason: command,
      );
    }
  });

  test('conversational greeting is deterministic', () {
    expect(
      parseHomeIntent('Hi how are you', hasAttachment: false).type,
      HomeIntentType.greeting,
    );
  });

  test('vague attachment remains metadata-first', () {
    expect(
      parseHomeIntent('', hasAttachment: true).type,
      HomeIntentType.vagueAttachment,
    );
    expect(metadataCategoryHint('tenancy-agreement.pdf'), 'Rentals');
    expect(metadataCategoryHint('image-1.png'), isNull);
  });

  test('text-only search, reminder, and vague requests are separated', () {
    expect(
      parseHomeIntent('Find my passport', hasAttachment: false).type,
      HomeIntentType.search,
    );
    expect(
      parseHomeIntent(
        'Remind me about the dentist on Friday',
        hasAttachment: false,
      ).type,
      HomeIntentType.reminder,
    );
    expect(
      parseHomeIntent(
        'Dentist appointment on 18 September at 9:30 am',
        hasAttachment: false,
      ).type,
      HomeIntentType.reminder,
    );
    expect(
      parseHomeIntent('Save this', hasAttachment: false).type,
      HomeIntentType.clarification,
    );
  });

  test('pasted web link is recognised as a saved-link request', () {
    final intent = parseHomeIntent(
      'Save this link - https://familydocuments.app/',
      hasAttachment: false,
    );
    expect(intent.type, HomeIntentType.saveLink);
    expect(intent.linkUrl, 'https://familydocuments.app/');
    expect(intent.linkTitle, 'familydocuments.app');
  });

  test('link parser excludes trailing sentence punctuation', () {
    final intent = parseHomeIntent(
      'Keep https://example.com/article.',
      hasAttachment: false,
    );
    expect(intent.type, HomeIntentType.saveLink);
    expect(intent.linkUrl, 'https://example.com/article');
  });

  test('markdown-formatted pasted link uses the URL and host title', () {
    final intent = parseHomeIntent(
      'Save this link - [https://familydocuments.app/](https://familydocuments.app/)',
      hasAttachment: false,
    );
    expect(intent.type, HomeIntentType.saveLink);
    expect(intent.linkUrl, 'https://familydocuments.app/');
    expect(intent.linkTitle, 'familydocuments.app');
  });
}
