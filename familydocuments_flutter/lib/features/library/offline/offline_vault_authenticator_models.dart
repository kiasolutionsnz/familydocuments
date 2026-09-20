abstract class OfflineVaultAuthenticator {
  Future<bool> isSupported();
  Future<bool> authenticate();
}
