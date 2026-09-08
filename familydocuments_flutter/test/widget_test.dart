import 'dart:convert';

import 'package:flutter/material.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:familydocuments_flutter/main.dart';
import 'package:familydocuments_flutter/core/auth/auth_service.dart';
import 'package:familydocuments_flutter/core/auth/session_store.dart';
import 'package:familydocuments_flutter/core/home/home_service.dart';

class Store implements SessionStore {
  String? value;
  @override
  Future<void> clear() async => value = null;
  @override
  Future<String?> readRefreshToken() async => value;
  @override
  Future<void> writeRefreshToken(String v) async => value = v;
}

class Client extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest r) async {
    final b = jsonEncode({
      'access_token':
          'x.${base64Url.encode(utf8.encode(jsonEncode({'exp': DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch ~/ 1000}))).replaceAll('=', '')}.x',
      'refresh_token': 'r',
      'user': {'id': 'u', 'email': 'ava@example.com'},
    });
    return http.StreamedResponse(Stream.value(utf8.encode(b)), 200, request: r);
  }
}

class FakeAuth extends AuthService {
  FakeAuth(this.current);
  Session? current;
  bool signedOut = false;
  @override
  Session? get session => current;
  @override
  Future<Session?> restore() async => current;
  @override
  Future<void> signOut() async {
    signedOut = true;
    current = null;
  }
}

class FakeHomeService extends HomeService {
  FakeHomeService(super.auth);
  int reminderCalls = 0;
  @override
  Future<List<AnalysisJob>> pendingAnalysisJobs() async => const [];
  @override
  Future<ReminderResult> createReminder({
    required String title,
    required String dueDate,
    String? dueTime,
    required String requestId,
    String? documentId,
  }) async {
    reminderCalls++;
    return ReminderResult(
      id: 'reminder-1',
      title: title,
      dueDate: dueDate,
      dueTime: dueTime,
    );
  }
}

void main() {
  testWidgets('shows session check before sign in', (t) async {
    await t.pumpWidget(const FamilyDocumentsApp());
    expect(find.text('Checking your session…'), findsOneWidget);
  });
  testWidgets('avatar opens settings placeholder', (t) async {
    await t.pumpWidget(
      FamilyDocumentsApp(
        auth: AuthService(store: Store(), client: Client()),
      ),
    );
    await t.pump();
    await t.enterText(find.byType(EditableText).first, 'a');
    await t.enterText(find.byType(EditableText).last, 'p');
    await t.tap(find.text('Sign in'));
    await t.pumpAndSettle();
    expect(find.text('A'), findsWidgets);
    await t.tap(find.byKey(const ValueKey('profile-avatar')));
    await t.pumpAndSettle();
    expect(find.text('Settings'), findsOneWidget);
    await t.tap(find.text('Settings'));
    await t.pumpAndSettle();
    expect(find.text('Settings will be connected in Phase 2.'), findsOneWidget);
  });
  testWidgets('avatar sign out returns to signed-out screen', (t) async {
    final auth = FakeAuth(
      Session(
        accessToken: 'access',
        refreshToken: 'refresh',
        email: 'ava@example.com',
        userId: 'u',
      ),
    );
    await t.pumpWidget(FamilyDocumentsApp(auth: auth));
    await t.pump();
    expect(find.text('A'), findsWidgets);
    await t.tap(find.byKey(const ValueKey('profile-avatar')));
    await t.pumpAndSettle();
    await t.tap(find.text('Sign out'));
    await t.pumpAndSettle();
    expect(auth.signedOut, isTrue);
    expect(find.text('Sign in'), findsOneWidget);
  });

  testWidgets('Home creates a standalone reminder without an attachment', (
    t,
  ) async {
    final auth = FakeAuth(
      Session(
        accessToken: 'access',
        refreshToken: 'refresh',
        email: 'ava@example.com',
        userId: 'u',
      ),
    );
    final home = FakeHomeService(auth);
    await t.pumpWidget(FamilyDocumentsApp(auth: auth, homeService: home));
    await t.pump();
    await t.enterText(
      find.byType(TextField).last,
      'Remind me about doctor appointment tomorrow at 2 pm',
    );
    await t.tap(find.byTooltip('Send').last);
    await t.pumpAndSettle();
    expect(home.reminderCalls, 1);
    expect(
      find.text('Reminder added: Doctor appointment — tomorrow at 2:00 pm'),
      findsOneWidget,
    );
  });

  testWidgets('Home asks for an ambiguous reminder date', (t) async {
    final auth = FakeAuth(
      Session(
        accessToken: 'access',
        refreshToken: 'refresh',
        email: 'ava@example.com',
        userId: 'u',
      ),
    );
    final home = FakeHomeService(auth);
    await t.pumpWidget(FamilyDocumentsApp(auth: auth, homeService: home));
    await t.pump();
    await t.enterText(
      find.byType(TextField).last,
      'Remind me sometime next month',
    );
    await t.tap(find.byTooltip('Send').last);
    await t.pump();
    expect(home.reminderCalls, 0);
    expect(find.text('What date next month should I use?'), findsOneWidget);
  });
}
