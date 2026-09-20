import 'dart:io';

import 'package:google_sign_in/google_sign_in.dart';

const _driveScope = 'https://www.googleapis.com/auth/drive.file';
const _iosClientId = String.fromEnvironment('GOOGLE_IOS_CLIENT_ID');

String? _configuredServerClientId;

Future<void> prepareDriveAuthorization() async {
  // Native Google Sign-In needs the OAuth "Web application" client ID here.
  // Its one-time server code is exchanged and retained by the backend; the
  // mobile app never stores a Google refresh token.
}

Future<String> requestDriveAuthorization(String clientId) async {
  if (clientId.trim().isEmpty) {
    throw StateError('Google Drive authorization is not configured.');
  }
  final signIn = GoogleSignIn.instance;
  if (_configuredServerClientId != clientId) {
    if (Platform.isIOS && _iosClientId.isEmpty) {
      throw StateError('Google Drive iPhone authorization is not configured.');
    }
    await signIn.initialize(
      clientId: Platform.isIOS ? _iosClientId : null,
      serverClientId: clientId,
    );
    _configuredServerClientId = clientId;
  }
  final account = await signIn.authenticate(scopeHint: const [_driveScope]);
  final authorization = await account.authorizationClient.authorizeServer(
    const [_driveScope],
  );
  final code = authorization?.serverAuthCode.trim() ?? '';
  if (code.isEmpty) {
    throw StateError(
      'Google did not return an offline authorization code. Remove '
      'FamilyDocuments from your Google account access, then try again.',
    );
  }
  return code;
}
