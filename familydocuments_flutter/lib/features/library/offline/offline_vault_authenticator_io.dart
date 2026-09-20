import 'dart:io';

import 'package:local_auth/local_auth.dart';

import 'offline_vault_authenticator_models.dart';

OfflineVaultAuthenticator createOfflineVaultAuthenticator() =>
    DeviceOfflineVaultAuthenticator();

class DeviceOfflineVaultAuthenticator implements OfflineVaultAuthenticator {
  DeviceOfflineVaultAuthenticator({LocalAuthentication? authentication})
    : _authentication = authentication ?? LocalAuthentication();

  final LocalAuthentication _authentication;

  @override
  Future<bool> isSupported() async {
    if (!Platform.isAndroid && !Platform.isIOS) return false;
    try {
      return await _authentication.isDeviceSupported();
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> authenticate() async {
    if (!await isSupported()) return false;
    try {
      return await _authentication.authenticate(
        localizedReason: 'Unlock your offline FamilyDocuments travel pack',
        biometricOnly: false,
        sensitiveTransaction: true,
        persistAcrossBackgrounding: true,
      );
    } catch (_) {
      return false;
    }
  }
}
