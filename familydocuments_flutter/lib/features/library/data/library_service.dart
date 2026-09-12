import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../../../core/auth/auth_service.dart';
import '../models/library_models.dart';

class LibraryServiceException implements Exception {
  const LibraryServiceException(
    this.message, {
    this.accessRevoked = false,
    this.conflict = false,
    this.providerDisconnected = false,
    this.temporary = false,
  });
  final String message;
  final bool accessRevoked, conflict, providerDisconnected, temporary;
}

class LibrarySource {
  const LibrarySource({
    required this.fileName,
    required this.mimeType,
    required this.bytes,
  });
  final String fileName, mimeType;
  final Uint8List bytes;
}

class LibraryService {
  LibraryService(this._auth, {http.Client? client})
    : _client = client ?? http.Client();
  final AuthService _auth;
  final http.Client _client;

  Future<http.Response> _post(String path, Map<String, dynamic> body) async {
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
      return response;
    } on AuthException {
      rethrow;
    } catch (_) {
      throw const LibraryServiceException(
        'Library could not be reached. Try again.',
      );
    }
  }

  Future<LibraryData> load({
    String query = '',
    String? categoryId,
    String? tag,
    LibrarySort sort = LibrarySort.newest,
    int limit = 40,
    int offset = 0,
  }) async {
    final response = await _post('/rest/rpc/library_workspace', {
      'search_query': query.trim().isEmpty ? null : query.trim(),
      'category_filter': categoryId,
      'tag_filter': tag,
      'sort_order': sort.name,
      'result_limit': limit,
      'result_offset': offset,
    });
    if (response.statusCode != 200) {
      throw const LibraryServiceException(
        'Library could not be loaded. Try again.',
      );
    }
    try {
      return LibraryData.fromJson(
        Map<String, dynamic>.from(jsonDecode(response.body) as Map),
      );
    } catch (_) {
      throw const LibraryServiceException(
        'Library returned an unexpected response.',
      );
    }
  }

  Future<void> updateDocument({
    required LibraryDocument document,
    required String categoryId,
    required List<String> tags,
  }) async {
    final normalised = <String>{};
    for (final tag in tags) {
      final value = tag.trim().toLowerCase();
      if (value.isNotEmpty) normalised.add(value);
    }
    final response = await _post('/rest/rpc/update_library_document', {
      'document': document.id,
      'category': categoryId,
      'confirmed_tags': normalised.toList(),
      'expected_updated_at': document.updatedAt.toUtc().toIso8601String(),
    });
    if (response.statusCode == 401 ||
        response.statusCode == 403 ||
        response.statusCode == 404) {
      throw const LibraryServiceException(
        'You no longer have access to this item.',
        accessRevoked: true,
      );
    }
    if (response.statusCode == 409) {
      throw const LibraryServiceException(
        'This document changed elsewhere. Refresh and try again.',
        conflict: true,
      );
    }
    if (response.statusCode != 200) {
      throw const LibraryServiceException(
        'Changes could not be saved. Try again.',
      );
    }
  }

  Future<LibraryCategory> createCategory(String name) async {
    final response = await _post('/rest/rpc/create_category', {
      'category_name': name.trim(),
    });
    if (response.statusCode != 200) {
      throw const LibraryServiceException(
        'That category could not be created. Try again.',
      );
    }
    final value = Map<String, dynamic>.from(jsonDecode(response.body) as Map);
    return LibraryCategory(
      id: value['id']?.toString() ?? '',
      name: value['name']?.toString() ?? name.trim(),
      count: 0,
      system: false,
    );
  }

  Future<LibrarySource> source(String documentId) async {
    final response = await _post('/rest/rpc/document_preview_source', {
      'document': documentId,
    });
    if (response.statusCode == 401 || response.statusCode == 403) {
      throw const LibraryServiceException(
        'You no longer have access to this item.',
        accessRevoked: true,
      );
    }
    if (response.statusCode == 404) {
      throw const LibraryServiceException(
        'You no longer have access to this item.',
        accessRevoked: true,
      );
    }
    if (response.statusCode != 200) {
      throw const LibraryServiceException(
        'The file could not be loaded. Try again.',
        temporary: true,
      );
    }
    try {
      final value = Map<String, dynamic>.from(jsonDecode(response.body) as Map);
      if (value['status'] == 'provider_disconnected') {
        throw const LibraryServiceException(
          'The storage connection needs to be reconnected.',
          providerDisconnected: true,
        );
      }
      if (value['status'] == 'file_unavailable') {
        throw const LibraryServiceException(
          'The original file is unavailable.',
        );
      }
      if (value['provider'] == 'google_drive') {
        final drive = await _post('/drive/open', {'document': documentId});
        if (drive.statusCode == 401 || drive.statusCode == 403) {
          throw const LibraryServiceException(
            'You no longer have access to this item.',
            accessRevoked: true,
          );
        }
        if (drive.statusCode == 409) {
          throw const LibraryServiceException(
            'The storage connection needs to be reconnected.',
            providerDisconnected: true,
          );
        }
        if (drive.statusCode == 404) {
          throw const LibraryServiceException(
            'The original file is unavailable.',
          );
        }
        if (drive.statusCode != 200) {
          throw const LibraryServiceException(
            'The file could not be loaded. Try again.',
            temporary: true,
          );
        }
        return _decodeSource(jsonDecode(drive.body) as Map);
      }
      return _decodeSource(value);
    } on LibraryServiceException {
      rethrow;
    } catch (_) {
      throw const LibraryServiceException(
        'The file could not be loaded. Try again.',
        temporary: true,
      );
    }
  }

  LibrarySource _decodeSource(Map value) {
    final encoded = value['content_base64'];
    if (encoded is! String || encoded.isEmpty) {
      throw const LibraryServiceException('The original file is unavailable.');
    }
    return LibrarySource(
      fileName: value['file_name']?.toString() ?? 'document',
      mimeType: value['mime_type']?.toString() ?? 'application/octet-stream',
      bytes: base64Decode(encoded.replaceAll(RegExp(r'\s'), '')),
    );
  }
}
