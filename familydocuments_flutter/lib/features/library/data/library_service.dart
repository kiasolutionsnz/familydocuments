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

  Future<void> createRentalProperty({
    required String name,
    required String address,
  }) => _collectionAction('create_rental_property', {
    'property_name': name.trim(),
    'property_address': address.trim(),
  });

  Future<void> addRentalBill({
    required String propertyId,
    required String documentId,
    required String category,
  }) => _collectionAction('create_rental_bill', {
    'property': propertyId,
    'document': documentId,
    'category': category,
  });

  Future<void> setRentalBillStatus(String billId, String status) =>
      _collectionAction('set_rental_bill_status', {
        'bill': billId,
        'new_status': status,
      });

  Future<void> addRentalIncome({
    required String propertyId,
    required String receivedDate,
    required num amount,
    required String description,
    String currency = 'NZD',
  }) => _collectionAction('add_rental_income', {
    'property': propertyId,
    'received_date': receivedDate,
    'received_amount': amount,
    'received_currency': currency,
    'income_description': description.trim(),
  });

  Future<Map<String, dynamic>> rentalFinancialYearReview({
    required String propertyId,
    required String financialYearStart,
  }) async {
    final response = await _post('/rest/rpc/rental_financial_year_review', {
      'property': propertyId,
      'financial_year_start': financialYearStart,
    });
    if (response.statusCode != 200) {
      throw const LibraryServiceException(
        'The financial-year review could not be loaded.',
      );
    }
    try {
      return Map<String, dynamic>.from(jsonDecode(response.body) as Map);
    } catch (_) {
      throw const LibraryServiceException(
        'The financial-year review returned an unexpected response.',
      );
    }
  }

  Future<void> createTravelTrip({
    required String name,
    String? destination,
    String? startDate,
    String? endDate,
  }) => _collectionAction('create_travel_trip', {
    'trip_name': name.trim(),
    'destination_name': destination?.trim(),
    'trip_start': startDate,
    'trip_end': endDate,
  });

  Future<void> addTravelRecord({
    required String tripId,
    required String documentId,
    required String kind,
  }) => _collectionAction('create_travel_record', {
    'trip': tripId,
    'document': documentId,
    'kind': kind,
  });

  Future<Map<String, dynamic>> travelWorkspace() async {
    final response = await _post('/rest/rpc/travel_workspace', const {});
    if (response.statusCode != 200) {
      throw const LibraryServiceException(
        'Travel records could not be loaded. Try again.',
      );
    }
    try {
      return Map<String, dynamic>.from(jsonDecode(response.body) as Map);
    } catch (_) {
      throw const LibraryServiceException(
        'Travel records returned an unexpected response.',
      );
    }
  }

  Future<void> updateTravelTrip({
    required String tripId,
    required String name,
    required String destination,
    required String startDate,
    required String endDate,
    required String currency,
    required num budget,
    required String status,
    required String notes,
  }) => _collectionAction('update_travel_trip', {
    'trip': tripId,
    'trip_name': name.trim(),
    'destination_name': destination.trim(),
    'trip_start': startDate.trim().isEmpty ? null : startDate.trim(),
    'trip_end': endDate.trim().isEmpty ? null : endDate.trim(),
    'home_currency_code': currency.trim().toUpperCase(),
    'budget_amount': budget,
    'trip_status': status,
    'trip_notes': notes.trim(),
  });

  Future<void> addTripTraveller({
    required String tripId,
    required String name,
  }) => _collectionAction('add_trip_traveller', {
    'trip': tripId,
    'traveller_name': name.trim(),
    'member': null,
  });

  Future<void> addTravelCost({
    required String tripId,
    required String category,
    required String status,
    required num amount,
    required String currency,
    required String notes,
  }) => _collectionAction('add_travel_cost', {
    'trip': tripId,
    'record': null,
    'category': category,
    'cost_status': status,
    'amount': amount,
    'currency': currency.trim().toUpperCase(),
    'exchange_rate': null,
    'rate_source': null,
    'rate_date': null,
    'notes': notes.trim(),
  });

  Future<void> addTravelItineraryEntry({
    required String tripId,
    required String kind,
    required String title,
    required String provider,
    required String origin,
    required String destination,
    required String startsAt,
    required String endsAt,
    required String bookingReference,
    required String notes,
  }) => _collectionAction('create_travel_itinerary_entry', {
    'trip': tripId,
    'item_kind': kind,
    'item_title': title.trim(),
    'provider_name': provider.trim(),
    'origin_name': origin.trim(),
    'destination_name': destination.trim(),
    'starts': startsAt.trim().isEmpty ? null : startsAt.trim(),
    'ends': endsAt.trim().isEmpty ? null : endsAt.trim(),
    'booking_ref': bookingReference.trim(),
    'item_notes': notes.trim(),
  });

  Future<void> _collectionAction(
    String operation,
    Map<String, dynamic> body,
  ) async {
    final response = await _post('/rest/rpc/$operation', body);
    if (response.statusCode == 401 || response.statusCode == 403) {
      throw const LibraryServiceException(
        'You do not have permission to change this Family collection.',
        accessRevoked: true,
      );
    }
    if (response.statusCode != 200) {
      throw const LibraryServiceException(
        'That collection change could not be saved. Check the details and try again.',
      );
    }
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
