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
  const DocumentMatch({
    required this.title,
    this.id,
    this.collection,
    this.date,
    this.matchType,
  });
  final String? id;
  final String title;
  final String? collection;
  final String? date;
  final String? matchType;
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
    this.id,
  });
  final String? id;
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

class SavedLinkCategory {
  const SavedLinkCategory({required this.id, required this.name});
  final String id;
  final String name;
}

class SavedLinkResult {
  const SavedLinkResult({
    required this.id,
    required this.title,
    required this.category,
    required this.duplicate,
  });
  final String id;
  final String title;
  final String category;
  final bool duplicate;
}

enum CategoryResolutionType { found, missing, ambiguous }

class CategoryResolution {
  const CategoryResolution._(
    this.type, {
    this.category,
    this.matches = const [],
  });

  const CategoryResolution.found(String category)
    : this._(CategoryResolutionType.found, category: category);

  const CategoryResolution.missing() : this._(CategoryResolutionType.missing);

  const CategoryResolution.ambiguous(List<String> matches)
    : this._(CategoryResolutionType.ambiguous, matches: matches);

  final CategoryResolutionType type;
  final String? category;
  final List<String> matches;
}

class AnalysisJob {
  const AnalysisJob({
    required this.id,
    required this.documentId,
    required this.status,
    this.result,
    this.failure,
    this.retryAllowed = false,
    this.displayTitle,
    this.category,
    this.tags = const [],
    this.createdAt,
    this.updatedAt,
  });
  final String id, documentId, status;
  final OrganisedDocument? result;
  final String? failure;
  final bool retryAllowed;
  final String? displayTitle;
  final String? category;
  final List<String> tags;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  bool get terminal =>
      status == 'succeeded' ||
      status == 'failed' ||
      status == 'permanent_failed' ||
      status == 'dismissed';

  AnalysisJob withDisplayTitle(String title) => AnalysisJob(
    id: id,
    documentId: documentId,
    status: status,
    result: result,
    failure: failure,
    retryAllowed: retryAllowed,
    displayTitle: title,
    category: category,
    tags: tags,
    createdAt: createdAt,
    updatedAt: updatedAt,
  );
}

class HomeService {
  HomeService(this._auth, {http.Client? client})
    : _client = client ?? http.Client();

  final AuthService _auth;
  final http.Client _client;

  Future<http.Response> _post(
    String path,
    Map<String, dynamic> body, {
    String networkError = 'FamilyDocuments could not be reached. Try again.',
  }) async {
    Future<http.Response> send() async {
      final token = await _auth.validAccessToken();
      try {
        return await _client.post(
          Uri.parse('$familyDocumentsApiBaseUrl$path'),
          headers: {
            'authorization': 'Bearer $token',
            'content-type': 'application/json',
          },
          body: jsonEncode(body),
        );
      } catch (_) {
        throw HomeServiceException(networkError);
      }
    }

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

  Future<ReminderResult> moveReminderOneWeekBefore({
    required String reminderId,
    required String expectedDueDate,
  }) async {
    final response = await _post('/rest/rpc/update_conversation_reminder', {
      'reminder': reminderId,
      'operation': 'one_week_before',
      'expected_due_date': expectedDueDate,
    });
    final payload = _json(response.body);
    if (response.statusCode != 200) {
      throw HomeServiceException(
        _plainError(
          payload,
          'That reminder changed or is no longer available. Try again.',
        ),
      );
    }
    return ReminderResult(
      id: payload['id']?.toString() ?? reminderId,
      title: payload['title']?.toString() ?? 'Reminder',
      dueDate: payload['due_at']?.toString() ?? expectedDueDate,
      dueTime: payload['due_time']?.toString(),
    );
  }

  Future<List<SavedLinkCategory>> linkCategories() async {
    final response = await _post('/rest/rpc/saved_link_workspace', const {
      'search_query': null,
      'category': null,
      'visibility': 'mine',
      'result_limit': 1,
    });
    final payload = _json(response.body);
    if (response.statusCode != 200) {
      throw HomeServiceException('Link categories are unavailable. Try again.');
    }
    return (payload['categories'] as List?)
            ?.whereType<Map>()
            .map(
              (value) => SavedLinkCategory(
                id: value['id']?.toString() ?? '',
                name: value['name']?.toString() ?? '',
              ),
            )
            .where((value) => value.id.isNotEmpty && value.name.isNotEmpty)
            .toList() ??
        const [];
  }

  Future<SavedLinkCategory> createLinkCategory(String name) async {
    final response = await _post('/rest/rpc/create_saved_link_category', {
      'category_name': name.trim(),
    });
    final payload = _json(response.body);
    if (response.statusCode != 200 || payload['id'] == null) {
      throw HomeServiceException(
        'That link category could not be created. Try another name.',
      );
    }
    return SavedLinkCategory(
      id: payload['id'].toString(),
      name: payload['name']?.toString() ?? name.trim(),
    );
  }

  Future<SavedLinkResult> saveLink({
    required String url,
    required String title,
    required SavedLinkCategory category,
  }) async {
    final response = await _post('/rest/rpc/create_saved_link', {
      'link_url': url,
      'link_title': title,
      'link_note': null,
      'category': category.id,
    });
    final payload = _json(response.body);
    if (response.statusCode != 200 || payload['id'] == null) {
      throw HomeServiceException('That link could not be saved. Try again.');
    }
    return SavedLinkResult(
      id: payload['id'].toString(),
      title: payload['title']?.toString() ?? title,
      category: category.name,
      duplicate:
          payload['duplicate_of'] != null || payload['duplicate'] == true,
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
    }, networkError: 'The file couldn’t be uploaded. Try again.');
    final payload = _json(response.body);
    if (response.statusCode != 202) {
      throw HomeServiceException(
        _plainError(payload, 'The file couldn’t be uploaded. Try again.'),
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

  Future<CategoryResolution> resolveCategory(String requested) async {
    return resolveCategoryName(requested, await categories());
  }

  Future<String> createCategory(String requested) async {
    final categoryName = canonicalCategoryName(requested);
    final existing = await resolveCategory(categoryName);
    if (existing.type == CategoryResolutionType.found) {
      return existing.category!;
    }
    final response = await _post('/rest/rpc/create_category', {
      'category_name': categoryName,
    });
    final payload = _json(response.body);
    if (response.statusCode == 200 && payload['name'] != null) {
      return payload['name'].toString();
    }
    // A repeated confirmation can race a successful first request. Resolve the
    // Family-scoped list again before reporting failure.
    final afterRetry = await resolveCategory(categoryName);
    if (afterRetry.type == CategoryResolutionType.found) {
      return afterRetry.category!;
    }
    throw HomeServiceException(
      response.statusCode == 401 || response.statusCode == 403
          ? 'Only a Family owner or admin can create categories.'
          : 'That category could not be created. Try again.',
    );
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

  Future<void> dismissAnalysisJob(String id) async {
    final response = await _post('/rest/rpc/dismiss_document_analysis_job', {
      'job': id,
    });
    if (response.statusCode != 200) {
      throw HomeServiceException(
        'This document could not be saved without reading. Try again.',
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
      id: payload['document_id']?.toString(),
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
        id: payload['document_id']?.toString(),
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
      displayTitle: payload['title']?.toString(),
      category: payload['category']?.toString(),
      tags:
          (payload['tags'] as List?)
              ?.map((value) => value.toString())
              .toList() ??
          const [],
      createdAt: DateTime.tryParse(payload['created_at']?.toString() ?? '')
          ?.toLocal(),
      updatedAt: DateTime.tryParse(
        (payload['completed_at'] ??
                    payload['updated_at'] ??
                    payload['started_at'] ??
                    payload['created_at'])
                ?.toString() ??
            '',
      )?.toLocal(),
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
    }, networkError: 'The file couldn’t be uploaded. Try again.');
    final payload = _json(response.body);
    if (response.statusCode != 200) {
      final message = payload['error'] == 'category_not_found'
          ? 'I couldn’t find that category. Choose or create one.'
          : 'Something went wrong while saving the document.';
      throw HomeServiceException(message);
    }
    return OrganisedDocument(
      title: payload['title']?.toString() ?? name,
      category: payload['category']?.toString() ?? category,
      tags:
          (payload['tags'] as List?)?.map((tag) => tag.toString()).toList() ??
          const [],
      pageCount: 0,
      id: payload['document_id']?.toString(),
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
      id: (value['document_id'] ?? value['id'])?.toString(),
      title: title.toString(),
      collection:
          (value['category_name'] ?? value['category'] ?? value['collection'])
              ?.toString(),
      matchType: (value['match_type'] ?? value['matched_field'])?.toString(),
      date:
          (value['important_date'] ??
                  value['critical_date'] ??
                  value['document_date'])
              ?.toString(),
    );
  }
}

CategoryResolution resolveCategoryName(
  String requested,
  Iterable<String> categories,
) {
  final names = categories
      .map((name) => name.trim())
      .where((name) => name.isNotEmpty)
      .toList();
  final requestedKey = _categoryKey(requested);
  if (requestedKey.isEmpty) return const CategoryResolution.missing();

  final alias = _categoryAlias(requestedKey);
  if (alias != null) {
    final matches = names
        .where((name) => _categoryKey(name) == _categoryKey(alias))
        .toList();
    return switch (matches.length) {
      0 => const CategoryResolution.missing(),
      1 => CategoryResolution.found(matches.single),
      _ => CategoryResolution.ambiguous(matches),
    };
  }

  final exact = names
      .where((name) => _categoryKey(name) == requestedKey)
      .toList();
  if (exact.length == 1) return CategoryResolution.found(exact.single);
  if (exact.length > 1) return CategoryResolution.ambiguous(exact);

  final matches = names.where((name) {
    final key = _categoryKey(name);
    return key.contains(requestedKey) || requestedKey.contains(key);
  }).toList();
  return switch (matches.length) {
    0 => const CategoryResolution.missing(),
    1 => CategoryResolution.found(matches.single),
    _ => CategoryResolution.ambiguous(matches),
  };
}

String canonicalCategoryName(String requested) {
  final key = _categoryKey(requested);
  return _categoryAlias(key) ??
      requested.trim().replaceFirst(
        RegExp(r'^(?:this\s+)?(?:as\s+)?', caseSensitive: false),
        '',
      );
}

String? _categoryAlias(String key) {
  if ({'rental', 'rental property'}.contains(key)) return 'Rentals';
  if (key == 'travel') return 'Travel';
  if (key == 'document') return 'Documents';
  return null;
}

String _categoryKey(String value) {
  var key = value
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9& ]+'), ' ')
      .replaceFirst(RegExp(r'^(?:this\s+)?(?:as\s+)?'), '')
      .replaceAll(
        RegExp(r'\b(?:document|documents|category|collection)\b'),
        ' ',
      )
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (key.endsWith('ies') && key.length > 3) {
    key = '${key.substring(0, key.length - 3)}y';
  } else if (key.endsWith('s') && !key.endsWith('ss') && key.length > 3) {
    key = key.substring(0, key.length - 1);
  }
  return key;
}
