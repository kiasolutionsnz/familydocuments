import 'package:familydocuments_flutter/core/security/public_https_url.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('only credential-free public HTTPS hostnames are accepted', () {
    expect(isPublicHttpsUrl('https://familydocuments.app/path'), isTrue);
    expect(
      publicHttpsHostname('https://familydocuments.app/path'),
      'familydocuments.app',
    );

    for (final value in [
      'http://familydocuments.app',
      'https://user:password@familydocuments.app',
      'https://localhost/path',
      'https://service.internal/path',
      'https://192.168.1.20/path',
      'https://8.8.8.8/path',
      'https://[2001:4860:4860::8888]/path',
      'javascript:alert(1)',
    ]) {
      expect(isPublicHttpsUrl(value), isFalse, reason: value);
      expect(publicHttpsHostname(value), isNull, reason: value);
    }
  });
}
