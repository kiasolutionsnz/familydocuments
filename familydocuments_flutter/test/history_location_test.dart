import 'package:flutter_test/flutter_test.dart';
import 'package:familydocuments_flutter/core/navigation/history_location.dart';

void main() {
  test('navigation preserves Flutter history serial and route state', () {
    final original = {
      'serialCount': 3,
      'state': {'route': '/'},
    };
    final next = historyWithLocation(original, 'library/documents');
    expect(next['serialCount'], 3);
    expect(next['state'], original['state']);
    expect(historyLocation(next), 'library/documents');
    expect(original.containsKey('familydocumentsLocation'), isFalse);
  });
  test('sign out resets app location without overwriting engine history', () {
    final state = historyWithLocation({'serialCount': 0}, 'inbox');
    final reset = historyWithLocation(state, 'home');
    expect(reset['serialCount'], 0);
    expect(historyLocation(reset), 'home');
  });
  test('legacy destinations and empty browser state remain readable', () {
    expect(historyLocation('timeline'), 'timeline');
    expect(historyLocation(null), '');
    expect(historyLocation({'serialCount': 0}), '');
  });
}
