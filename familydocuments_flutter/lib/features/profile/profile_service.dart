import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../core/auth/auth_service.dart';

class ProfileException implements Exception {
  ProfileException(this.message);
  final String message;
}

class ProfileFamily {
  const ProfileFamily(this.name, this.role, this.joinedAt);
  final String name, role;
  final DateTime? joinedAt;
}

class MemberProfile {
  const MemberProfile({
    required this.displayName,
    required this.families,
    this.photoMime,
    this.photoBase64,
    this.updatedAt,
  });
  final String displayName;
  final String? photoMime, photoBase64;
  final DateTime? updatedAt;
  final List<ProfileFamily> families;

  factory MemberProfile.fromJson(Map<String, dynamic> value) => MemberProfile(
    displayName: value['display_name']?.toString() ?? '',
    photoMime: value['photo_mime']?.toString(),
    photoBase64: value['photo_base64']?.toString(),
    updatedAt: DateTime.tryParse(value['updated_at']?.toString() ?? ''),
    families: (value['families'] as List? ?? const [])
        .whereType<Map>()
        .map(
          (item) => ProfileFamily(
            item['name']?.toString() ?? '',
            item['role']?.toString() ?? '',
            DateTime.tryParse(item['joined_at']?.toString() ?? ''),
          ),
        )
        .toList(),
  );
}

class ProfileService {
  ProfileService(this.auth, {http.Client? client})
    : client = client ?? http.Client();
  final AuthService auth;
  final http.Client client;

  Future<MemberProfile> load() => _rpc('my_profile', const {});

  Future<MemberProfile> save({
    required String displayName,
    String? photoMime,
    String? photoBase64,
    bool removePhoto = false,
  }) => _rpc('save_my_profile', {
    'new_name': displayName.trim(),
    'new_photo_mime': photoMime,
    'new_photo_base64': photoBase64,
    'remove_photo': removePhoto,
  });

  Future<bool> deleteAccount() async {
    final result = await _rpcJson('delete_my_account', {
      'confirmation': 'DELETE',
    });
    return result['deleted'] == true &&
        result['google_drive_files_deleted'] == false;
  }

  Future<MemberProfile> _rpc(String name, Map<String, dynamic> payload) async {
    final value = await _rpcJson(name, payload);
    return MemberProfile.fromJson(value);
  }

  Future<Map<String, dynamic>> _rpcJson(
    String name,
    Map<String, dynamic> payload,
  ) async {
    try {
      final token = await auth.validAccessToken();
      final response = await client
          .post(
            Uri.parse('$familyDocumentsApiBaseUrl/rest/rpc/$name'),
            headers: {
              'authorization': 'Bearer $token',
              'content-type': 'application/json',
            },
            body: jsonEncode(payload),
          )
          .timeout(const Duration(seconds: 30));
      if (response.statusCode != 200) {
        throw ProfileException(
          name == 'delete_my_account'
              ? response.statusCode == 409
                    ? 'Transfer Family ownership before deleting this account.'
                    : 'Your account could not be deleted. Please try again or contact support.'
              : 'Profile could not be ${name == 'my_profile' ? 'loaded' : 'saved'}. Please try again.',
        );
      }
      return jsonDecode(response.body) as Map<String, dynamic>;
    } on ProfileException {
      rethrow;
    } on AuthException {
      throw ProfileException('Please sign in again to manage your profile.');
    } catch (_) {
      throw ProfileException('Profile is unavailable. Please try again.');
    }
  }
}
