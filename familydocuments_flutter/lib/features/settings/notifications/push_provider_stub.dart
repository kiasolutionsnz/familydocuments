abstract class PushProvider {
  bool get isSupported;
  bool get isConfigured;
  Future<String> enable();
  Future<void> disable();
  Stream<String> get tokenRefreshes;
}

PushProvider createPushProvider() => _UnavailablePushProvider();

class _UnavailablePushProvider implements PushProvider {
  @override
  bool get isSupported => false;
  @override
  bool get isConfigured => false;
  @override
  Stream<String> get tokenRefreshes => const Stream.empty();
  @override
  Future<String> enable() => throw UnsupportedError(
    'Push notifications are available in the Android and iPhone apps.',
  );
  @override
  Future<void> disable() async {}
}
