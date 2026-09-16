import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:familydocuments_flutter/core/auth/auth_service.dart';
import 'package:familydocuments_flutter/features/lists/lists_page.dart';

class FakeLists extends ListsService {
  FakeLists():super(AuthService());
  final calls=<String>[];
  bool fail=false;
  @override Future<Map<String,dynamic>> call(String op,Map<String,dynamic> body) async {
    calls.add(op);
    if(fail) throw Exception('Try again');
    if(op=='household_lists_dashboard') return {'lists':[{'id':'list-1','title':'Weekly shopping','kind':'groceries'}]};
    if(op=='household_list_workspace') return {'items':[{'id':'item-1','title':'Milk','quantity':'2 litres','section':'Dairy','notes':'','recurrence':'none','version':1}],'members':[],'history':[]};
    return {};
  }
}
void main(){
  testWidgets('reminder copy needs explicit Save on a phone layout', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final service = FakeLists();
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: ListsPage(
      auth: AuthService(), service: service, initialTitle: 'Buy medicine',
    ))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Weekly shopping'));
    await tester.pumpAndSettle();
    expect(find.text('Buy medicine'), findsOneWidget);
    expect(service.calls, isNot(contains('save_household_list_item')));
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(service.calls, contains('save_household_list_item'));
    service.dispose();
  });
  testWidgets('opens a shared list and persists completion', (tester) async {
    final service=FakeLists();
    await tester.pumpWidget(MaterialApp(home:Scaffold(body:ListsPage(auth:AuthService(),service:service))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Weekly shopping'));await tester.pumpAndSettle();
    expect(find.text('Milk'),findsOneWidget);
    await tester.tap(find.byType(Checkbox));await tester.pumpAndSettle();
    expect(service.calls,contains('complete_household_list_item'));
    service.dispose();
  });
  testWidgets('failed add preserves the entered title', (tester) async {
    final service=FakeLists();
    await tester.pumpWidget(MaterialApp(home:Scaffold(body:ListsPage(auth:AuthService(),service:service))));
    await tester.pumpAndSettle();await tester.tap(find.text('Weekly shopping'));await tester.pumpAndSettle();
    await tester.tap(find.text('Add item'));await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first,'Bread');service.fail=true;
    await tester.tap(find.text('Save'));await tester.pumpAndSettle();
    expect(find.text('Bread'),findsOneWidget);expect(find.textContaining('Try again'),findsOneWidget);
    service.dispose();
  });
}
