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
  });

  test('invoice attachment explicitly requests OCR', () {
    expect(
      parseHomeIntent('Read this bill as an invoice', hasAttachment: true).type,
      HomeIntentType.invoiceAttachment,
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
      parseHomeIntent('Save this', hasAttachment: false).type,
      HomeIntentType.clarification,
    );
  });
}
