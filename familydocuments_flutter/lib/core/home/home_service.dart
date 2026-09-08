import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import '../auth/auth_service.dart';

class HomeServiceException implements Exception {
  HomeServiceException(this.message);
  final String message;
}

class DocumentMatch {
  const DocumentMatch({required this.title, this.collection, this.date});
  final String title;
  final String? collection;
  final String? date;
}

class SearchResponse {
  const SearchResponse({required this.answer, required this.documents});
  final String answer;
  final List<DocumentMatch> documents;
}

class OrganisedDocument {
  const OrganisedDocument({
    required this.title,
    required this.category,
    required this.tags,
    required this.pageCount,
  });
  final String title;
  final String category;
  final List<String> tags;
  final int pageCount;
}

class HomeService {
  HomeService(this._auth, {http.Client? client})
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

    var response = await send();
    if (response.statusCode == 401) {
      await _auth.refresh();
      response = await send();
    }
    return response;
  }

  Future<SearchResponse> search(String query) async {
    final response = await _post('/search/ask', {'query': query});
    final payload = _json(response.body);
    if (response.statusCode != 200) {
      throw HomeServiceException(
        payload['error']?.toString() ??
            'Search could not be reached. Try again.',
      );
    }
    final sources = payload['sources'];
    final documents = sources is List
        ? sources
              .whereType<Map>()
              .map(_document)
              .whereType<DocumentMatch>()
              .toList()
        : const <DocumentMatch>[];
    return SearchResponse(
      answer:
          payload['answer']?.toString() ??
          'Matching documents are shown below.',
      documents: documents,
    );
  }

  Future<OrganisedDocument> analyseUpload({
    required String name,
    required String mimeType,
    required Uint8List bytes,
  }) async {
    if (!{'application/pdf', 'image/jpeg', 'image/png'}.contains(mimeType)) {
      throw HomeServiceException('Choose a PDF, JPEG or PNG file.');
    }
    if (bytes.isEmpty || bytes.lengthInBytes > 5 * 1024 * 1024) {
      throw HomeServiceException('Choose a file smaller than 5 MB.');
    }
    final response = await _post('/documents/analyse', {
      'file_name': name,
      'mime_type': mimeType,
      'sha256': sha256.convert(bytes).toString(),
      'content_base64': base64Encode(bytes),
    });
    final payload = _json(response.body);
    if (response.statusCode != 200) {
      final message = payload['error'] == 'document_could_not_be_read'
          ? 'No readable text was found in $name.'
          : 'Your document could not be organised. Please try again.';
      throw HomeServiceException(message);
    }
    return OrganisedDocument(
      title: payload['title']?.toString() ?? name,
      category: payload['category']?.toString() ?? 'Documents',
      tags:
          (payload['tags'] as List?)?.map((tag) => tag.toString()).toList() ??
          const [],
      pageCount: (payload['pages'] as num?)?.toInt() ?? 0,
    );
  }

  Future<OrganisedDocument> saveUpload({
    required String name,
    required String mimeType,
    required Uint8List bytes,
    required String category,
  }) async {
    if (!{'application/pdf', 'image/jpeg', 'image/png'}.contains(mimeType)) {
      throw HomeServiceException('Choose a PDF, JPEG or PNG file.');
    }
    if (bytes.isEmpty || bytes.lengthInBytes > 5 * 1024 * 1024) {
      throw HomeServiceException('Choose a file smaller than 5 MB.');
    }
    final response = await _post('/documents/save', {
      'file_name': name,
      'mime_type': mimeType,
      'sha256': sha256.convert(bytes).toString(),
      'content_base64': base64Encode(bytes),
      'category': category,
    });
    final payload = _json(response.body);
    if (response.statusCode != 200) {
      final message = payload['error'] == 'category_not_found'
          ? 'I could not find that category in your Family.'
          : 'Your document could not be saved. Please try again.';
      throw HomeServiceException(message);
    }
    return OrganisedDocument(
      title: payload['title']?.toString() ?? name,
      category: payload['category']?.toString() ?? category,
      tags:
          (payload['tags'] as List?)?.map((tag) => tag.toString()).toList() ??
          const [],
      pageCount: 0,
    );
  }

  static Map<String, dynamic> _json(String body) {
    try {
      final decoded = jsonDecode(body);
      return decoded is Map<String, dynamic> ? decoded : <String, dynamic>{};
    } on FormatException {
      return <String, dynamic>{};
    }
  }

  static DocumentMatch? _document(Map value) {
    final title = value['document_title'] ?? value['title'] ?? value['name'];
    if (title == null || title.toString().trim().isEmpty) return null;
    return DocumentMatch(
      title: title.toString(),
      collection:
          (value['category_name'] ?? value['category'] ?? value['collection'])
              ?.toString(),
      date:
          (value['important_date'] ??
                  value['critical_date'] ??
                  value['document_date'])
              ?.toString(),
    );
  }
}
