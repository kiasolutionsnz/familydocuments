import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import '../../core/auth/auth_service.dart';

class FeedbackTicket {
  FeedbackTicket(this.data);
  final Map<String, dynamic> data;
  String get id => data['id'] as String;
  String get reference => data['reference'] as String;
  String get title => data['title'] as String;
  String get status => data['status'] as String;
  String get question => data['question'] as String? ?? '';
  String get summary =>
      '$reference: $title\n$status${question.isEmpty ? '' : '\n$question'}';
}

abstract class FeedbackRepository {
  Future<List<FeedbackTicket>> list();
  Future<FeedbackTicket> request(
    String operation, {
    String? message,
    String? ticket,
    String? conversation,
  });
}

class FeedbackService implements FeedbackRepository {
  FeedbackService(this.auth, {http.Client? client})
    : client = client ?? http.Client();
  final AuthService auth;
  final http.Client client;
  Future<dynamic> _send(Map<String, dynamic> body) async {
    Future<http.Response> send() async => client
        .post(
          Uri.parse('$familyDocumentsApiBaseUrl/conversation/feedback'),
          headers: {
            'authorization': 'Bearer ${await auth.validAccessToken()}',
            'content-type': 'application/json',
          },
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 20));
    var response = await send();
    if (response.statusCode == 401) {
      await auth.refresh();
      response = await send();
    }
    if (response.statusCode != 200) {
      throw StateError(
        'Feedback could not be updated. Try again or sign in again.',
      );
    }
    return jsonDecode(response.body);
  }

  @override
  Future<List<FeedbackTicket>> list() async {
    final data = await _send({'operation': 'list'});
    return (data['tickets'] as List)
        .map((t) => FeedbackTicket(Map<String, dynamic>.from(t as Map)))
        .toList();
  }

  @override
  Future<FeedbackTicket> request(
    String operation, {
    String? message,
    String? ticket,
    String? conversation,
  }) async {
    // Stable across lost responses and refresh; scoped to reporter by the server.
    final key = sha256
        .convert(
          utf8.encode(jsonEncode([operation, conversation, ticket, message])),
        )
        .toString();
    return FeedbackTicket(
      Map<String, dynamic>.from(
        await _send({
          'operation': operation,
          'request_key': key,
          'message': ?message,
          'ticket': ?ticket,
          'conversation': ?conversation,
          'app_version': const String.fromEnvironment(
            'APP_VERSION',
            defaultValue: 'development',
          ),
        }) as Map,
      ),
    );
  }
}

bool isExplicitFeedback(String text) => RegExp(
  r'^(feedback\s*:|add (this|that) to (the )?backlog\b|.*\bcreate (a )?feedback ticket\b)',
  caseSensitive: false,
).hasMatch(text.trim());
