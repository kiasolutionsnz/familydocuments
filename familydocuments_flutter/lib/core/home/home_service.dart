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

class ReminderResult {
  const ReminderResult({
    required this.id,
    required this.title,
    required this.dueDate,
    this.dueTime,
  });
  final String id, title, dueDate;
  final String? dueTime;
}

class AnalysisJob {
  const AnalysisJob({
    required this.id,
    required this.documentId,
    required this.status,
    this.result,
    this.failure,
    this.retryAllowed = false,
  });
  final String id, documentId, status;
  final OrganisedDocument? result;
  final String? failure;
  final bool retryAllowed;
  bool get terminal =>
      status == 'succeeded' ||
      status == 'failed' ||
      status == 'permanent_failed';
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

  Future<http.Response> _get(String path) async {
    Future<http.Response> send() async => _client.get(
      Uri.parse('$familyDocumentsApiBaseUrl$path'),
      headers: {'authorization': 'Bearer ${await _auth.validAccessToken()}'},
    );
    var response = await send();
    if (response.statusCode == 401) {
      await _auth.refresh();
      response = await send();
    }
    return response;
  }

  Future<ReminderResult> createReminder({
    required String title,
    required String dueDate,
    String? dueTime,
    required String requestId,
    String? documentId,
  }) async {
    final response = await _post('/rest/rpc/create_reminder', {
      'reminder_title': title,
      'due_date': dueDate,
      'due_time_value': dueTime,
      'due_timezone': 'Pacific/Auckland',
      'related_document': documentId,
      'request_id': requestId,
    });
    final payload = _json(response.body);
    if (response.statusCode != 200) {
      throw HomeServiceException(
        _plainError(payload, 'Your reminder could not be added. Try again.'),
      );
    }
    return ReminderResult(
      id: payload['id']?.toString() ?? '',
      title: payload['title']?.toString() ?? title,
      dueDate: payload['due_at']?.toString() ?? dueDate,
      dueTime: payload['due_time']?.toString(),
    );
  }

  Future<AnalysisJob> submitAnalysisJob({
    required String name,
    required String mimeType,
    required Uint8List bytes,
    required bool invoice,
    required String idempotencyKey,
  }) async {
    _validateUpload(mimeType, bytes);
    final response = await _post('/document-analysis/jobs', {
      'file_name': name,
      'mime_type': mimeType,
      'sha256': sha256.convert(bytes).toString(),
      'content_base64': base64Encode(bytes),
      'mode': invoice ? 'invoice' : 'document',
      'idempotency_key': idempotencyKey,
    });
    final payload = _json(response.body);
    if (response.statusCode != 202) {
      throw HomeServiceException(
        _plainError(payload, 'Your document could not be queued. Try again.'),
      );
    }
    return _job(payload);
  }

  Future<AnalysisJob> analysisJob(String id) async {
    final response = await _get('/document-analysis/jobs/$id');
    final payload = _json(response.body);
    if (response.statusCode != 200) {
      throw HomeServiceException(
        _plainError(payload, 'Processing status is unavailable.'),
      );
    }
    return _job(payload);
  }

  Future<List<AnalysisJob>> pendingAnalysisJobs() async {
    final response = await _post(
      '/rest/rpc/pending_document_analysis_jobs',
      const {},
    );
    if (response.statusCode != 200) return const [];
    try {
      final decoded = jsonDecode(response.body);
      return decoded is List
          ? decoded
                .whereType<Map>()
                .map((value) => _job(Map<String, dynamic>.from(value)))
                .toList()
          : const [];
    } on FormatException {
      return const [];
    }
  }

  Future<AnalysisJob> retryAnalysisJob(String id) async {
    final response = await _post('/document-analysis/jobs/$id/retry', const {});
    final payload = _json(response.body);
    if (response.statusCode != 200) {
      throw HomeServiceException(
        _plainError(payload, 'This document could not be retried.'),
      );
    }
    return _job(payload);
  }

  Future<List<String>> categories() async {
    final response = await _post('/rest/rpc/household_snapshot', const {});
    final payload = _json(response.body);
    if (response.statusCode != 200) {
      throw HomeServiceException('Categories are unavailable. Try again.');
    }
    return (payload['categories'] as List?)
            ?.whereType<Map>()
            .map((value) => value['name']?.toString())
            .whereType<String>()
            .toList() ??
        const [];
  }

  Future<void> categorizeAnalysisJob(String id, String category) async {
    final response = await _post('/rest/rpc/categorize_document_analysis_job', {
      'job': id,
      'category_name': category,
    });
    if (response.statusCode != 200) {
      throw HomeServiceException(
        'That category could not be applied. Try again.',
      );
    }
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

  static void _validateUpload(String mimeType, Uint8List bytes) {
    if (!{'application/pdf', 'image/jpeg', 'image/png'}.contains(mimeType)) {
      throw HomeServiceException('Choose a PDF, JPEG or PNG file.');
    }
    if (bytes.isEmpty || bytes.lengthInBytes > 5 * 1024 * 1024) {
      throw HomeServiceException('Choose a file smaller than 5 MB.');
    }
  }

  static AnalysisJob _job(Map<String, dynamic> payload) {
    final raw = payload['result'];
    OrganisedDocument? result;
    if (raw is Map) {
      result = OrganisedDocument(
        title: raw['title']?.toString() ?? 'Document',
        category: raw['category']?.toString() ?? 'Documents',
        tags:
            (raw['tags'] as List?)?.map((value) => value.toString()).toList() ??
            const [],
        pageCount: (raw['pages'] as num?)?.toInt() ?? 0,
      );
    }
    return AnalysisJob(
      id: payload['job_id']?.toString() ?? '',
      documentId: payload['document_id']?.toString() ?? '',
      status: payload['status']?.toString() ?? 'queued',
      result: result,
      failure: payload['failure']?.toString(),
      retryAllowed: payload['retry_allowed'] == true,
    );
  }

  static String _plainError(Map<String, dynamic> payload, String fallback) {
    return switch (payload['error']) {
      'authentication_required' => 'Sign in is required.',
      'job_not_found' => 'This processing job is no longer available.',
      _ => fallback,
    };
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
