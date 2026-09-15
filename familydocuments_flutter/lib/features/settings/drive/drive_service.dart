import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../../core/auth/auth_service.dart';

enum DriveConnectionState {
  notConnected,
  chooseFolder,
  connected,
  reconnectRequired,
  disconnected,
}

class DriveConnection {
  const DriveConnection({
    required this.state,
    required this.familyId,
    required this.canManage,
    this.folderName,
    this.folderId,
  });

  final DriveConnectionState state;
  final String familyId;
  final bool canManage;
  final String? folderName;
  final String? folderId;
  // Connection readiness only, never permission to write a Family document.
  // The save endpoint must separately authorize the actor for every mutation.
  bool get canSave => state == DriveConnectionState.connected;

  factory DriveConnection.fromJson(Map<String, dynamic> value) {
    final state = switch (value['status']) {
      'not_connected' => DriveConnectionState.notConnected,
      'authorised' => DriveConnectionState.chooseFolder,
      'active' => DriveConnectionState.connected,
      'reconnect_required' => DriveConnectionState.reconnectRequired,
      'disconnected' => DriveConnectionState.disconnected,
      _ => throw const FormatException('Invalid Drive connection state'),
    };
    final family = value['household_id'];
    if (family is! String ||
        family.isEmpty ||
        value['can_manage'] is! bool ||
        (value['folder_name'] != null && value['folder_name'] is! String) ||
        (value['folder_id'] != null && value['folder_id'] is! String) ||
        (state == DriveConnectionState.connected &&
            value['credential_available'] != true)) {
      throw const FormatException('Incomplete Drive connection');
    }
    return DriveConnection(
      state: state,
      familyId: family,
      canManage: value['can_manage'] as bool,
      folderName: value['folder_name'] as String?,
      folderId: value['folder_id'] as String?,
    );
  }
}

class DriveException implements Exception {
  const DriveException(this.message);
  final String message;
}

abstract class DriveRepository {
  Future<DriveConnection> status();
  Future<void> connect(String code);
  Future<List<DriveFolder>> folders();
  Future<DriveFolder> createFolder(String name);
  Future<void> selectFolder(String id);
  Future<void> disconnect();
}

class DriveFolder {
  const DriveFolder(this.id, this.name);
  final String id, name;
  factory DriveFolder.fromJson(Map<String, dynamic> value) {
    if (value['id'] is! String ||
        value['name'] is! String ||
        (value['id'] as String).isEmpty ||
        (value['name'] as String).isEmpty) {
      throw const FormatException('Invalid folder');
    }
    return DriveFolder(value['id'] as String, value['name'] as String);
  }
}

/// No connection cache: each read uses the current actor and active Family.
/// The database remains authoritative; canManage is presentation data only.
class DriveService implements DriveRepository {
  DriveService(this.auth, {http.Client? client})
    : client = client ?? http.Client();

  final AuthService auth;
  final http.Client client;
  String? _expectedFamily;

  Future<dynamic> _request(String path, {Map<String, dynamic>? body}) async {
    try {
      if (_expectedFamily == null) {
        throw const DriveException(
          'Refresh the connection before changing Google Drive.',
        );
      }
      final headers = {
        'authorization': 'Bearer ${await auth.validAccessToken()}',
        'content-type': 'application/json',
        'x-requested-with': 'XmlHttpRequest',
        'x-family-context': _expectedFamily!,
      };
      final uri = Uri.parse('$familyDocumentsApiBaseUrl/drive/$path');
      final response =
          await (body == null
                  ? client.get(uri, headers: headers)
                  : client.post(uri, headers: headers, body: jsonEncode(body)))
              .timeout(const Duration(seconds: 40));
      // Do not replay a mutation on timeout or authentication failure.
      if (response.statusCode == 401) {
        throw AuthException(
          'Sign in again to connect Google Drive.',
          expired: true,
        );
      }
      if (response.statusCode == 403) {
        throw const DriveException(
          'A Family administrator must verify their identity before changing Google Drive.',
        );
      }
      if (response.statusCode == 409) {
        throw const DriveException('Reconnect Google Drive, then try again.');
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw const DriveException(
          'Google Drive could not complete this request. Check the connection and try again.',
        );
      }
      return response.body.isEmpty ? null : jsonDecode(response.body);
    } on AuthException {
      rethrow;
    } on DriveException {
      rethrow;
    } catch (_) {
      throw const DriveException(
        'The response could not be confirmed. Refresh the connection before trying again.',
      );
    }
  }

  @override
  Future<void> connect(String code) async {
    await _request('connect', body: {'code': code});
  }

  @override
  Future<List<DriveFolder>> folders() async {
    final value = await _request('folders');
    if (value is! Map || value['files'] is! List) {
      throw const DriveException('Folders could not be loaded. Try again.');
    }
    return (value['files'] as List)
        .map((v) => DriveFolder.fromJson(Map<String, dynamic>.from(v as Map)))
        .toList();
  }

  @override
  Future<DriveFolder> createFolder(String name) async => DriveFolder.fromJson(
    Map<String, dynamic>.from(
      await _request('folders', body: {'name': name.trim()}) as Map,
    ),
  );

  /// Creates a registered app-owned child in the selected shared Library tree.
  /// Callers must show the proposed destination and obtain confirmation first.
  Future<DriveFolder> createLibraryFolder({
    required String nodeKey,
    required String nodeKind,
    required String parentFolderId,
    required String name,
  }) async {
    final value = await _request(
      'library-folders',
      body: {
        'node_key': nodeKey,
        'node_kind': nodeKind,
        'parent_folder_id': parentFolderId,
        'name': name.trim(),
      },
    );
    if (value is! Map) {
      throw const DriveException('The Library folder could not be confirmed.');
    }
    return DriveFolder.fromJson(Map<String, dynamic>.from(value));
  }

  Future<void> moveLibraryDocument({
    required String documentId,
    required String folderId,
  }) async {
    await _request(
      'library-move',
      body: {'document': documentId, 'folder_id': folderId},
    );
  }

  @override
  Future<void> selectFolder(String id) async {
    await _request('folders/select', body: {'id': id});
  }

  @override
  Future<void> disconnect() async {
    await _request('disconnect', body: {});
  }

  @override
  Future<DriveConnection> status() async {
    _expectedFamily = null;
    try {
      Future<http.Response> send() async => client
          .post(
            Uri.parse(
              '$familyDocumentsApiBaseUrl/rest/rpc/household_google_drive_connection_summary',
            ),
            headers: {
              'authorization': 'Bearer ${await auth.validAccessToken()}',
              'content-type': 'application/json',
            },
            body: '{}',
          )
          .timeout(const Duration(seconds: 20));
      var response = await send();
      if (response.statusCode == 401) {
        await auth.refresh();
        response = await send();
      }
      if (response.statusCode == 409) {
        throw const DriveException('Choose a Family before connecting Drive.');
      }
      if (response.statusCode == 403) {
        throw const DriveException('You no longer have access to this Family.');
      }
      if (response.statusCode != 200) {
        throw const DriveException(
          'Google Drive status could not be loaded. Try again.',
        );
      }
      final value = jsonDecode(response.body);
      if (value is! Map<String, dynamic>) throw const FormatException();
      final connection = DriveConnection.fromJson(value);
      _expectedFamily = connection.familyId;
      return connection;
    } on AuthException {
      rethrow;
    } on DriveException {
      rethrow;
    } catch (_) {
      throw const DriveException(
        'Google Drive status could not be loaded. Try again.',
      );
    }
  }
}
