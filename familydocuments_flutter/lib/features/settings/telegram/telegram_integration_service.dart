import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';

import '../../../core/auth/auth_service.dart';

class TelegramIntegrationException implements Exception {
  const TelegramIntegrationException(this.message);
  final String message;
}

class TelegramConnection {
  const TelegramConnection({
    required this.connected,
    required this.selectionRequired,
    this.familyId,
    this.familyName,
    this.displayName,
    this.username,
    this.connectedAt,
  });
  final bool connected;
  final bool selectionRequired;
  final String? familyId, familyName, displayName, username;
  final DateTime? connectedAt;

  factory TelegramConnection.fromJson(Map<String, dynamic> value) =>
      TelegramConnection(
        connected: value['connected'] == true,
        selectionRequired: value['selection_required'] == true,
        familyId: value['family_id']?.toString(),
        familyName: value['family_name']?.toString(),
        displayName: value['display_name']?.toString(),
        username: value['username']?.toString(),
        connectedAt: DateTime.tryParse(value['connected_at']?.toString() ?? ''),
      );
}

class TelegramConnectLink {
  const TelegramConnectLink({required this.url, required this.expiresAt});
  final String url;
  final DateTime expiresAt;
}

abstract class TelegramIntegrationRepository {
  Future<TelegramConnection> status();
  Future<TelegramConnectLink> connect(String familyId);
  Future<void> disconnect(String familyId);
}

class TelegramIntegrationService implements TelegramIntegrationRepository {
  TelegramIntegrationService(this._auth, {http.Client? client})
    : _client = client ?? http.Client();
  final AuthService _auth;
  final http.Client _client;

  Future<Map<String, dynamic>> _post(
    String path,
    Map<String, dynamic> body,
  ) async {
    Future<http.Response> send() async => _client.post(
      Uri.parse('$familyDocumentsApiBaseUrl$path'),
      headers: {
        'authorization': 'Bearer ${await _auth.validAccessToken()}',
        'content-type': 'application/json',
      },
      body: jsonEncode(body),
    );
    try {
      var response = await send();
      if (response.statusCode == 401) {
        await _auth.refresh();
        response = await send();
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw const TelegramIntegrationException(
          'Telegram could not be updated. Try again.',
        );
      }
      final decoded = jsonDecode(response.body);
      if (decoded is! Map) throw const FormatException();
      return Map<String, dynamic>.from(decoded);
    } on TelegramIntegrationException {
      rethrow;
    } on AuthException {
      rethrow;
    } catch (_) {
      throw const TelegramIntegrationException(
        'Telegram could not be reached. Try again.',
      );
    }
  }

  @override
  Future<TelegramConnection> status() async => TelegramConnection.fromJson(
    await _post('/integrations/telegram/status', const {}),
  );

  @override
  Future<TelegramConnectLink> connect(String familyId) async {
    final value = await _post('/integrations/telegram/connect', {
      'family_id': familyId,
    });
    final url = value['deep_link']?.toString() ?? '';
    final expires = DateTime.tryParse(value['expires_at']?.toString() ?? '');
    final parsed = Uri.tryParse(url);
    final productionLink =
        parsed != null && parsed.scheme == 'https' && parsed.host == 't.me';
    final disposableLink =
        kDebugMode &&
        parsed != null &&
        parsed.scheme == 'http' &&
        (parsed.host == '127.0.0.1' || parsed.host == 'localhost');
    if (expires == null || (!productionLink && !disposableLink)) {
      throw const TelegramIntegrationException(
        'Telegram returned an invalid connection link.',
      );
    }
    return TelegramConnectLink(url: url, expiresAt: expires);
  }

  @override
  Future<void> disconnect(String familyId) async {
    await _post('/integrations/telegram/disconnect', {
      'family_id': familyId,
      'confirm': true,
    });
  }
}
