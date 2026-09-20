import 'offline_vault_authenticator_models.dart';

OfflineVaultAuthenticator createOfflineVaultAuthenticator() =>
    _UnsupportedOfflineVaultAuthenticator();

class _UnsupportedOfflineVaultAuthenticator
    implements OfflineVaultAuthenticator {
  @override
  Future<bool> isSupported() async => false;

  @override
  Future<bool> authenticate() async => false;
}
