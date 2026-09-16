import 'package:familydocuments_flutter/core/auth/auth_service.dart';
import 'package:familydocuments_flutter/features/reminders/data/reminder_service.dart';
import 'package:familydocuments_flutter/features/reminders/models/reminder_models.dart';
import 'package:familydocuments_flutter/features/reminders/reminders_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

ReminderItem item(String id, String state) => ReminderItem(
  id: id,
  title: id,
  dueAt: DateTime(2027, 1, 10),
  status: state == 'completed' ? state : 'upcoming',
  dueState: state,
  recurrence: 'none',
  audience: 'personal',
);

class Service extends ReminderService {
  Service() : super(AuthService());
  bool fail = false;
  final calls = <String>[];
  var items = [
    item('Next bill', 'upcoming'),
    item('Late bill', 'overdue'),
    item('Paid bill', 'completed'),
  ];
  @override
  Future<ReminderDashboard> load() async {
    if (fail) throw const ReminderServiceException('Unavailable');
    return ReminderDashboard(items: items);
  }

  @override
  Future<void> act(String id, String action, {String? snoozeUntil}) async {
    calls.add('$id:$action');
    items = items.map((r) => r.id == id ? item(id, 'completed') : r).toList();
  }

  @override
  Future<void> configure(String id, String recurrence) async =>
      calls.add('$id:$recurrence');
}

void main() {
  Future<void> open(WidgetTester tester, Service service) async {
    await tester.pumpWidget(MaterialApp(home: RemindersPage(service: service)));
    await tester.pumpAndSettle();
  }

  testWidgets('upcoming overdue and completed show separate reminders', (
    tester,
  ) async {
    await open(tester, Service());
    expect(find.text('Next bill'), findsOneWidget);
    expect(find.text('Late bill'), findsNothing);
    await tester.tap(find.text('Overdue').first);
    await tester.pumpAndSettle();
    expect(find.text('Late bill'), findsOneWidget);
    expect(find.text('Next bill'), findsNothing);
    await tester.tap(find.text('Completed').first);
    await tester.pumpAndSettle();
    expect(find.text('Paid bill'), findsOneWidget);
    expect(find.text('Complete'), findsNothing);
  });
  testWidgets('completion reloads and moves the reminder to completed', (
    tester,
  ) async {
    final service = Service();
    await open(tester, service);
    await tester.tap(find.text('Complete'));
    await tester.pumpAndSettle();
    expect(service.calls, ['Next bill:complete']);
    expect(find.text('Next bill'), findsNothing);
    await tester.tap(find.text('Completed').first);
    await tester.pumpAndSettle();
    expect(find.text('Next bill'), findsOneWidget);
  });
  testWidgets('failed retry stays recoverable without an unhandled exception', (
    tester,
  ) async {
    final service = Service()..fail = true;
    await open(tester, service);
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    service.fail = false;
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(find.text('Next bill'), findsOneWidget);
  });
  testWidgets('repeat selection updates the existing reminder', (tester) async {
    final service = Service();
    await open(tester, service);
    await tester.tap(find.text('Repeat'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Repeat monthly'));
    await tester.pumpAndSettle();
    expect(service.calls, ['Next bill:monthly']);
  });
  testWidgets(
    'snooze picker matches the server one year limit and cancel is safe',
    (tester) async {
      final service = Service();
      await open(tester, service);
      await tester.tap(find.text('Snooze'));
      await tester.pumpAndSettle();
      final picker = tester.widget<DatePickerDialog>(
        find.byType(DatePickerDialog),
      );
      expect(picker.lastDate.difference(picker.firstDate).inDays, 364);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(service.calls, isEmpty);
    },
  );
  testWidgets('reminder controls fit a phone width', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await open(tester, Service());
    expect(tester.takeException(), isNull);
  });
}
