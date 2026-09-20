import 'package:familydocuments_flutter/core/auth/auth_service.dart';
import 'package:familydocuments_flutter/features/settings/notifications/push_notification_page.dart';
import 'package:familydocuments_flutter/features/settings/notifications/push_notification_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _PushRepository implements PushNotificationRepository {
  _PushRepository({this.enabled = false});
  bool enabled;
  int enables = 0, disables = 0;
  @override
  bool get configured => true;
  @override
  bool get supported => true;
  @override
  Future<bool> loadEnabled() async => enabled;
  @override
  Future<void> enable() async { enabled = true; enables++; }
  @override
  Future<void> disable() async { enabled = false; disables++; }
  @override
  void dispose() {}
}

void main() {
  testWidgets('member explicitly enables and disables phone reminders', (tester) async {
    final repository = _PushRepository();
    await tester.pumpWidget(MaterialApp(home: PushNotificationPage(auth: AuthService(), repository: repository)));
    await tester.pumpAndSettle();

    final toggle = find.byKey(const ValueKey('push-reminders-toggle'));
    expect(tester.widget<SwitchListTile>(toggle).value, isFalse);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(repository.enables, 1);
    expect(tester.widget<SwitchListTile>(toggle).value, isTrue);

    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(repository.disables, 1);
    expect(tester.widget<SwitchListTile>(toggle).value, isFalse);
  });
}
